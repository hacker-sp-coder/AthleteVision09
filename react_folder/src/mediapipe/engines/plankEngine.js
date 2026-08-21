/**
 * Straight-arm plank hold engine — ported from plank_engine.dart.
 *
 * Same body config as push-up TOP position, held statically.
 * Reuses push-up's proven FormChecks plus arm extension check.
 */
import { ExerciseEngine, ExerciseStatus } from './exerciseEngine.js';
import { BodyPoint } from '../sidedPose.js';
import { resolveSidedPose } from '../sidedPose.js';
import { MIN_LANDMARK_VISIBILITY } from '../poseUtils.js';
import {
  CheckStatus, ExerciseReference,
  RequiredLandmarksCheck, SideOrientationCheck,
  BodyInclinationCheck, BodyRigidityCheck, LegExtensionCheck,
} from './formCheck.js';

const State = Object.freeze({ SETUP: 'setup', HOLDING: 'holding', ENDED: 'ended' });

export class PlankEngine extends ExerciseEngine {
  constructor() {
    super();
    this._setupInstruction =
      'Turn sideways to the camera, keep your entire body visible, and get into the straight-arm push-up (plank) position — arms and legs extended, body straight. Hold as long as possible.';
    this._requiredPoints = [
      BodyPoint.SHOULDER, BodyPoint.ELBOW, BodyPoint.WRIST,
      BodyPoint.HIP, BodyPoint.KNEE, BodyPoint.ANKLE,
    ];
    this._postureChecks = [
      new RequiredLandmarksCheck(),
      new SideOrientationCheck(),
      new BodyInclinationCheck({
        from: BodyPoint.SHOULDER, to: BodyPoint.ANKLE,
        maxInclinationFromHorizontalDeg: 40,
        invalidReason: 'Get into a horizontal plank position - straight line from shoulders to ankles',
      }),
      new BodyRigidityCheck({
        a: BodyPoint.SHOULDER, b: BodyPoint.HIP, c: BodyPoint.ANKLE,
        absoluteMinDeg: 155, toleranceDeg: 18,
      }),
      new LegExtensionCheck(),
      new LegExtensionCheck({
        a: BodyPoint.SHOULDER, b: BodyPoint.ELBOW, c: BodyPoint.WRIST,
        absoluteMinDeg: 155, toleranceDeg: 20,
        key: 'armExtensionAngleDeg', checkName: 'arm_extension',
        notVisibleReason: 'Arms not visible',
        invalidReason: 'Keep your arms straight - do not bend your elbows',
      }),
    ];
    this._stabilityWindowMs = 1500;
    this._maxUncertainFrames = 5;
    this._invalidConfirmationMs = 800;
    this._maxFrameTickMs = 400;
    this.reset();
  }

  reset() {
    this._preferredSideIsLeft = null;
    this._state = State.SETUP;
    this._isBodyVisible = false;
    this._stableSince = null;
    this._stabilitySamples = [];
    this._calibrationMessage = this._setupInstruction;
    this._reference = null;
    this._lastTickTime = null;
    this._consecutiveUncertain = 0;
    this._invalidSince = null;
    this._holdReason = '';
    this._totalValidMs = 0;
  }

  _evaluate(landmarks, useCalibratedReference) {
    if (!landmarks || landmarks.length === 0) {
      return { status: CheckStatus.UNCERTAIN, reason: 'Body not detected', context: null };
    }

    const sidedPose = resolveSidedPose(
      landmarks, this._requiredPoints, MIN_LANDMARK_VISIBILITY, this._preferredSideIsLeft
    );
    if (sidedPose) this._preferredSideIsLeft = sidedPose.isLeftSide;

    const ctx = {
      landmarks, sidedPose,
      reference: useCalibratedReference ? this._reference : null,
    };
    for (const check of this._postureChecks) {
      const result = check.evaluate(ctx);
      if (result.status !== CheckStatus.VALID) {
        return { status: result.status, reason: result.reason, context: ctx };
      }
    }
    return { status: CheckStatus.VALID, reason: '', context: ctx };
  }

  _buildReference(samples) {
    const values = {};
    for (const check of this._postureChecks) {
      const key = check.referenceKey;
      if (!key) continue;
      const vals = samples.map((s) => check.sampleValue(s)).filter((v) => v != null);
      if (vals.length === 0) continue;
      values[key] = vals.reduce((a, b) => a + b, 0) / vals.length;
    }
    return new ExerciseReference(values);
  }

  processLandmarks(landmarks) {
    if (this._state === State.ENDED) return;
    const now = Date.now();
    if (this._state === State.SETUP) this._processSetup(landmarks, now);
    else if (this._state === State.HOLDING) this._processHolding(landmarks, now);
  }

  _processSetup(landmarks, now) {
    this._isBodyVisible = landmarks && landmarks.length > 0;
    const result = this._evaluate(landmarks, false);

    if (result.status !== CheckStatus.VALID) {
      this._stableSince = null;
      this._stabilitySamples = [];
      this._calibrationMessage = result.reason || this._setupInstruction;
      return;
    }

    if (!this._stableSince) this._stableSince = now;
    this._stabilitySamples.push(result.context);
    const elapsed = now - this._stableSince;

    if (elapsed >= this._stabilityWindowMs) {
      this._reference = this._buildReference(this._stabilitySamples);
      this._state = State.HOLDING;
      this._lastTickTime = now;
      this._consecutiveUncertain = 0;
      this._invalidSince = null;
      this._holdReason = '';
      this._totalValidMs = 0;
      return;
    }

    const pct = Math.min(100, Math.round((elapsed / this._stabilityWindowMs) * 100));
    this._calibrationMessage = `Hold still... ${pct}%`;
  }

  _processHolding(landmarks, now) {
    this._isBodyVisible = landmarks && landmarks.length > 0;
    const result = this._evaluate(landmarks, true);

    let dt = this._lastTickTime ? now - this._lastTickTime : 0;
    if (dt > this._maxFrameTickMs) dt = this._maxFrameTickMs;
    this._lastTickTime = now;

    switch (result.status) {
      case CheckStatus.VALID:
        this._consecutiveUncertain = 0;
        this._invalidSince = null;
        this._holdReason = '';
        this._totalValidMs += dt;
        break;
      case CheckStatus.UNCERTAIN:
        this._consecutiveUncertain++;
        this._holdReason = result.reason;
        if (this._consecutiveUncertain > this._maxUncertainFrames) {
          this._confirmInvalid(now);
        }
        break;
      case CheckStatus.INVALID:
        this._consecutiveUncertain = 0;
        this._holdReason = result.reason;
        this._confirmInvalid(now);
        break;
    }
  }

  _confirmInvalid(now) {
    if (!this._invalidSince) this._invalidSince = now;
    if (now - this._invalidSince >= this._invalidConfirmationMs) {
      this._state = State.ENDED;
    }
  }

  _fmt(ms) { return `${(ms / 1000).toFixed(1)}s`; }

  get status() {
    switch (this._state) {
      case State.SETUP:
        if (!this._isBodyVisible) {
          return new ExerciseStatus({
            primaryText: this._setupInstruction,
            secondaryText: 'Body not detected',
            isBodyVisible: false,
          });
        }
        if (!this._stableSince) {
          return new ExerciseStatus({
            primaryText: 'Get into position',
            secondaryText: this._calibrationMessage,
            isBodyVisible: true,
          });
        }
        return new ExerciseStatus({
          primaryText: 'Hold still...',
          secondaryText: this._calibrationMessage,
          isBodyVisible: true,
        });

      case State.HOLDING:
        return new ExerciseStatus({
          primaryText: `Plank Hold: ${this._fmt(this._totalValidMs)}`,
          secondaryText: this._holdReason ? `Form: ${this._holdReason}` : 'Holding - keep your body straight',
          isBodyVisible: this._isBodyVisible,
        });

      case State.ENDED:
        return new ExerciseStatus({
          primaryText: `Plank Hold: ${this._fmt(this._totalValidMs)}`,
          secondaryText: this._holdReason ? `Ended - ${this._holdReason}` : 'Test ended',
          isBodyVisible: this._isBodyVisible,
        });
    }
  }
}
