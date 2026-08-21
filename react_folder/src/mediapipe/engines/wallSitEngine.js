/**
 * Wall-sit isometric hold engine — ported from wall_sit_engine.dart.
 *
 * Side-on, knee angle held near 90° for as long as possible.
 * Accumulates elapsed valid-hold time directly (no rep counting).
 */
import { ExerciseEngine, ExerciseStatus } from './exerciseEngine.js';
import { CheckStatus, RequiredLandmarksCheck, SideOrientationCheck } from './formCheck.js';
import { resolveSidedPose, BodyPoint } from '../sidedPose.js';
import { angleBetweenPoints, MIN_LANDMARK_VISIBILITY } from '../poseUtils.js';

const State = Object.freeze({ SETUP: 'setup', HOLDING: 'holding', ENDED: 'ended' });

export class WallSitEngine extends ExerciseEngine {
  constructor() {
    super();
    this._setupInstruction =
      'Stand side-on with your back against a wall. Lower until your knees are around 90°. Cross your arms and hold.';
    this._minKneeAngleDeg = 80;
    this._maxKneeAngleDeg = 100;
    this._stabilityWindowMs = 1500;
    this._exitDebounceMs = 2000;
    this._maxFrameTickMs = 400;
    this._requiredPoints = [BodyPoint.SHOULDER, BodyPoint.HIP, BodyPoint.KNEE, BodyPoint.ANKLE];
    this._postureChecks = [new RequiredLandmarksCheck(), new SideOrientationCheck()];
    this.reset();
  }

  reset() {
    this._preferredSideIsLeft = null;
    this._state = State.SETUP;
    this._isBodyVisible = false;
    this._stableSince = null;
    this._calibrationMessage = this._setupInstruction;
    this._lastTickTime = null;
    this._invalidSince = null;
    this._holdReason = '';
    this._totalValidMs = 0;
    this._totalElapsedMs = 0;
    this._currentStreakMs = 0;
    this._maxContinuousValidMs = 0;
  }

  _evaluate(landmarks) {
    if (!landmarks || landmarks.length === 0) {
      return { valid: false, reason: 'Body not detected' };
    }

    const sidedPose = resolveSidedPose(
      landmarks, this._requiredPoints, MIN_LANDMARK_VISIBILITY, this._preferredSideIsLeft
    );
    if (sidedPose) this._preferredSideIsLeft = sidedPose.isLeftSide;

    const ctx = { landmarks, sidedPose, reference: null };
    for (const check of this._postureChecks) {
      const result = check.evaluate(ctx);
      if (result.status !== CheckStatus.VALID) {
        return { valid: false, reason: result.reason };
      }
    }

    const hip = sidedPose.points[BodyPoint.HIP];
    const knee = sidedPose.points[BodyPoint.KNEE];
    const ankle = sidedPose.points[BodyPoint.ANKLE];
    if (!hip || !knee || !ankle) {
      return { valid: false, reason: 'Legs not fully visible' };
    }

    const kneeAngle = angleBetweenPoints(hip, knee, ankle);
    if (kneeAngle > this._maxKneeAngleDeg) {
      return { valid: false, reason: 'Lower into the wall-sit position - bend your knees more' };
    }
    if (kneeAngle < this._minKneeAngleDeg) {
      return { valid: false, reason: 'Come up slightly - knees are bent too far' };
    }
    return { valid: true, reason: '' };
  }

  processLandmarks(landmarks) {
    if (this._state === State.ENDED) return;
    const now = Date.now();
    if (this._state === State.SETUP) this._processSetup(landmarks, now);
    else if (this._state === State.HOLDING) this._processHolding(landmarks, now);
  }

  _processSetup(landmarks, now) {
    this._isBodyVisible = landmarks && landmarks.length > 0;
    const result = this._evaluate(landmarks);

    if (!result.valid) {
      this._stableSince = null;
      this._calibrationMessage = result.reason;
      return;
    }

    if (!this._stableSince) this._stableSince = now;
    if (now - this._stableSince >= this._stabilityWindowMs) {
      this._state = State.HOLDING;
      this._lastTickTime = now;
      this._totalValidMs = 0;
      this._totalElapsedMs = 0;
      this._currentStreakMs = 0;
      this._maxContinuousValidMs = 0;
      this._invalidSince = null;
      this._holdReason = '';
    }
  }

  _processHolding(landmarks, now) {
    this._isBodyVisible = landmarks && landmarks.length > 0;
    const result = this._evaluate(landmarks);

    let dt = this._lastTickTime ? now - this._lastTickTime : 0;
    if (dt > this._maxFrameTickMs) dt = this._maxFrameTickMs;
    this._lastTickTime = now;
    this._totalElapsedMs += dt;

    if (result.valid) {
      this._invalidSince = null;
      this._holdReason = '';
      this._totalValidMs += dt;
      this._currentStreakMs += dt;
      if (this._currentStreakMs > this._maxContinuousValidMs) {
        this._maxContinuousValidMs = this._currentStreakMs;
      }
      return;
    }

    this._currentStreakMs = 0;
    this._holdReason = result.reason;
    if (!this._invalidSince) this._invalidSince = now;
    if (now - this._invalidSince >= this._exitDebounceMs) {
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
          secondaryText: `Confirming position (${Math.min(100, Math.round(((Date.now() - this._stableSince) / this._stabilityWindowMs) * 100))}%)`,
          isBodyVisible: true,
        });

      case State.HOLDING:
        return new ExerciseStatus({
          primaryText: `Hold time: ${this._fmt(this._totalValidMs)}`,
          secondaryText: this._holdReason ? `Paused - ${this._holdReason}` : 'Holding - keep your knees near 90°',
          isBodyVisible: this._isBodyVisible,
        });

      case State.ENDED: {
        const pct = this._totalElapsedMs > 0
          ? Math.round((this._totalValidMs / this._totalElapsedMs) * 100) : 0;
        return new ExerciseStatus({
          primaryText: `Final hold time: ${this._fmt(this._totalValidMs)}`,
          secondaryText: `In range: ${pct}%   •   Best streak: ${this._fmt(this._maxContinuousValidMs)}`,
          isBodyVisible: this._isBodyVisible,
        });
      }
    }
  }
}
