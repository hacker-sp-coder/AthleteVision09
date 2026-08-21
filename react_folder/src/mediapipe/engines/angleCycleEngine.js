/**
 * Angle-cycle rep-counting engine — ported from angle_cycle_engine.dart.
 *
 * Reusable rep-cycle mechanics for any exercise whose reps are
 * characterized by a single joint angle cycling TOP → DESCENDING →
 * BOTTOM → ASCENDING → TOP. All exercise-specific biomechanics live
 * in the ExerciseConfig it's constructed with.
 */
import { ExerciseEngine, ExerciseStatus } from './exerciseEngine.js';
import {
  CheckStatus, FormCheckResult, ExerciseReference,
  BottomEventOutcome,
} from './formCheck.js';
import { resolveSidedPose } from '../sidedPose.js';
import { angleBetweenPoints, averageHipY, averageShoulderY } from '../poseUtils.js';

const Phase = Object.freeze({
  TOP: 'TOP',
  DESCENDING: 'DESCENDING',
  BOTTOM: 'BOTTOM',
  ASCENDING: 'ASCENDING',
});

export class AngleCycleEngine extends ExerciseEngine {
  constructor(config) {
    super();
    this.config = config;
    this._maxWarnings = 2;
    this._reversalThresholdDeg = 6.0;
    this._eventSampleWindow = 5;
    this.reset();
  }

  reset() {
    this._preferredSideIsLeft = null;
    this._calibrated = false;
    this._stableSince = null;
    this._stabilitySamples = [];
    this._reference = null;
    this._calibrationMessage = this.config.setupInstruction;
    this._smoothedAngle = null;
    this._phase = Phase.TOP;
    this._repCount = 0;
    this._lastRepTime = null;
    this._descentMinAngle = null;
    this._hipYWindow = [];
    this._shoulderYWindow = [];
    this._consecutiveUncertain = 0;
    this._formStatus = CheckStatus.UNCERTAIN;
    this._formReason = '';
    this._formAdvisory = null;
    this._isBodyVisible = false;
    this._invalidSince = null;
    this._violationConfirmedThisEpisode = false;
    this._warningCount = 0;
    this._terminated = false;
  }

  _evaluateChecks(ctx) {
    for (const check of this.config.formChecks) {
      const result = check.evaluate(ctx);
      if (result.status !== CheckStatus.VALID) return result;
    }
    return FormCheckResult.OK;
  }

  _primaryAngle(ctx) {
    const sided = ctx.sidedPose;
    if (!sided) return null;
    const [a, b, c] = this.config.angleLandmarks;
    const pa = sided.points[a];
    const pb = sided.points[b];
    const pc = sided.points[c];
    if (!pa || !pb || !pc) return null;
    return angleBetweenPoints(pa, pb, pc);
  }

  get _topThreshold() {
    if (this.config.topAngleThresholdDeg != null) return this.config.topAngleThresholdDeg;
    if (this.config.topAngleReferenceKey && this._reference) {
      return this._reference.get(this.config.topAngleReferenceKey);
    }
    return null;
  }

  get _bottomThreshold() {
    if (this.config.bottomAngleThresholdDeg != null) return this.config.bottomAngleThresholdDeg;
    const top = this._topThreshold;
    const rom = this.config.targetRomDeg;
    if (top == null || rom == null) return null;
    return top - rom;
  }

  _buildReference(samples) {
    const values = {};
    for (const check of this.config.formChecks) {
      const key = check.referenceKey;
      if (!key) continue;
      const vals = samples.map((s) => check.sampleValue(s)).filter((v) => v != null);
      if (vals.length === 0) continue;
      values[key] = vals.reduce((a, b) => a + b, 0) / vals.length;
    }
    return new ExerciseReference(values);
  }

  processLandmarks(landmarks) {
    if (this._terminated) return;

    if (!landmarks || landmarks.length === 0) {
      this._isBodyVisible = false;
      if (!this._calibrated) {
        this._stableSince = null;
        this._stabilitySamples = [];
        this._calibrationMessage = this.config.setupInstruction;
      } else {
        this._registerCheckResult(
          new FormCheckResult(CheckStatus.UNCERTAIN, 'Body not detected')
        );
      }
      return;
    }

    this._isBodyVisible = true;

    if (!this._calibrated) {
      this._processCalibrationFrame(landmarks);
    } else {
      this._processTrackingFrame(landmarks);
    }
  }

  _processCalibrationFrame(landmarks) {
    const sidedPose = resolveSidedPose(
      landmarks,
      this.config.requiredPoints,
      this.config.landmarkConfidenceThreshold,
      this._preferredSideIsLeft
    );
    if (sidedPose) this._preferredSideIsLeft = sidedPose.isLeftSide;

    const ctx = { landmarks, sidedPose, reference: null };
    const result = this._evaluateChecks(ctx);

    if (result.status === CheckStatus.VALID) {
      const isFirstFrame = this._stableSince == null;
      if (!this._stableSince) this._stableSince = Date.now();
      this._stabilitySamples.push(ctx);
      const elapsed = Date.now() - this._stableSince;

      if (elapsed >= this.config.stabilityWindowMs) {
        this._reference = this._buildReference(this._stabilitySamples);
        this._calibrated = true;
        this._phase = Phase.TOP;
        this._smoothedAngle = this._primaryAngle(ctx);
        this._calibrationMessage = 'Starting position locked';
      } else if (isFirstFrame) {
        this._calibrationMessage = 'Valid position detected - hold still...';
      } else {
        const pct = Math.min(100, Math.round((elapsed / this.config.stabilityWindowMs) * 100));
        this._calibrationMessage = `Hold still... ${pct}%`;
      }
      return;
    }

    this._stableSince = null;
    this._stabilitySamples = [];
    this._calibrationMessage = !sidedPose ? this.config.setupInstruction : result.reason;
  }

  _processTrackingFrame(landmarks) {
    const sidedPose = resolveSidedPose(
      landmarks,
      this.config.requiredPoints,
      this.config.landmarkConfidenceThreshold,
      this._preferredSideIsLeft
    );
    if (sidedPose) this._preferredSideIsLeft = sidedPose.isLeftSide;

    const ctx = { landmarks, sidedPose, reference: this._reference };
    const result = this._evaluateChecks(ctx);

    const hipY = averageHipY(landmarks);
    if (hipY != null) this._pushSample(this._hipYWindow, hipY);
    const shoulderY = averageShoulderY(landmarks);
    if (shoulderY != null) this._pushSample(this._shoulderYWindow, shoulderY);

    const rawAngle = this._primaryAngle(ctx);
    if (rawAngle != null) {
      this._smoothedAngle = this._smoothedAngle == null
        ? rawAngle
        : this.config.emaAlpha * rawAngle + (1 - this.config.emaAlpha) * this._smoothedAngle;
    }

    this._registerCheckResult(result, rawAngle);
    this._updateFormAdvisory(rawAngle);
  }

  _updateFormAdvisory(angle) {
    const excessiveRom = this.config.excessiveRomDeg;
    const message = this.config.excessiveRomMessage;
    if (excessiveRom == null || message == null) return;

    if (this._phase === Phase.TOP) {
      this._formAdvisory = null;
      return;
    }

    const top = this._topThreshold;
    if (angle == null || top == null) return;
    if (top - angle > excessiveRom) this._formAdvisory = message;
  }

  _registerCheckResult(result, movementAngle = null) {
    switch (result.status) {
      case CheckStatus.VALID:
        this._consecutiveUncertain = 0;
        this._formStatus = CheckStatus.VALID;
        this._formReason = result.reason;
        if (movementAngle != null) this._advancePhase(movementAngle);
        break;
      case CheckStatus.UNCERTAIN:
        this._consecutiveUncertain++;
        this._formReason = result.reason;
        if (this._consecutiveUncertain > this.config.maxUncertainFrames) {
          this._formStatus = CheckStatus.INVALID;
          this._invalidateTrajectory();
        } else {
          this._formStatus = CheckStatus.UNCERTAIN;
        }
        break;
      case CheckStatus.INVALID:
        this._consecutiveUncertain = 0;
        this._formStatus = CheckStatus.INVALID;
        this._formReason = result.reason;
        this._invalidateTrajectory();
        break;
    }
    this._updateLifecycle();
  }

  _invalidateTrajectory() {
    this._phase = Phase.TOP;
    this._descentMinAngle = null;
    this._hipYWindow = [];
    this._shoulderYWindow = [];
  }

  _pushSample(window, value) {
    window.push(value);
    if (window.length > this._eventSampleWindow) window.shift();
  }

  _updateLifecycle() {
    switch (this._formStatus) {
      case CheckStatus.VALID:
        this._invalidSince = null;
        this._violationConfirmedThisEpisode = false;
        break;
      case CheckStatus.INVALID: {
        const now = Date.now();
        if (!this._invalidSince) this._invalidSince = now;
        if (!this._violationConfirmedThisEpisode &&
            now - this._invalidSince >= this.config.sustainedInvalidConfirmationMs) {
          this._violationConfirmedThisEpisode = true;
          this._registerConfirmedViolation();
        }
        break;
      }
      case CheckStatus.UNCERTAIN:
        break;
    }
  }

  _registerConfirmedViolation() {
    this._warningCount++;
    if (this._warningCount > this._maxWarnings) {
      this._terminated = true;
    }
  }

  _advancePhase(angle) {
    const top = this._topThreshold;
    const bottom = this._bottomThreshold;
    if (top == null || bottom == null) return;

    switch (this._phase) {
      case Phase.TOP:
        if (angle < top) {
          this._phase = Phase.DESCENDING;
          this._descentMinAngle = angle;
        }
        break;
      case Phase.DESCENDING: {
        if (this._descentMinAngle == null || angle < this._descentMinAngle) {
          this._descentMinAngle = angle;
        }
        if (angle >= top) {
          this._phase = Phase.TOP;
          this._descentMinAngle = null;
        } else if (angle - this._descentMinAngle >= this._reversalThresholdDeg) {
          if (this._descentMinAngle <= bottom) {
            this._confirmBottom(angle);
          } else {
            this._descentMinAngle = angle;
          }
        }
        break;
      }
      case Phase.BOTTOM:
        if (angle > bottom) {
          this._phase = Phase.ASCENDING;
        }
        break;
      case Phase.ASCENDING:
        if (angle >= top) {
          const now = Date.now();
          if (!this._lastRepTime || now - this._lastRepTime >= this.config.minRepIntervalMs) {
            this._repCount++;
            this._lastRepTime = now;
          }
          this._phase = Phase.TOP;
          this._descentMinAngle = null;
        } else if (angle <= bottom) {
          this._phase = Phase.BOTTOM;
        }
        break;
    }
  }

  _confirmBottom(angle) {
    const validator = this.config.bottomEventValidator;
    const reference = this._reference;
    if (!validator || !reference) {
      this._phase = Phase.BOTTOM;
      return;
    }

    const result = validator.validate({
      reference,
      hipYSamples: [...this._hipYWindow],
      shoulderYSamples: [...this._shoulderYWindow],
    });

    switch (result.outcome) {
      case BottomEventOutcome.VALID:
        this._phase = Phase.BOTTOM;
        break;
      case BottomEventOutcome.NO_QUALIFYING_ATTEMPT:
      case BottomEventOutcome.INSUFFICIENT_DEPTH:
        this._invalidateTrajectory();
        break;
      case BottomEventOutcome.FORM_VIOLATION:
        this._formStatus = CheckStatus.INVALID;
        this._formReason = result.reason;
        this._invalidateTrajectory();
        this._violationConfirmedThisEpisode = true;
        if (!this._invalidSince) this._invalidSince = Date.now();
        this._registerConfirmedViolation();
        break;
      case BottomEventOutcome.UNCERTAIN:
        this._descentMinAngle = angle;
        break;
    }
  }

  get status() {
    if (this._terminated) {
      return new ExerciseStatus({
        primaryText: 'TEST TERMINATED',
        secondaryText: `Final rep count: ${this._repCount}`,
        isBodyVisible: this._isBodyVisible,
      });
    }

    if (!this._isBodyVisible) {
      return new ExerciseStatus({
        primaryText: this.config.setupInstruction,
        secondaryText: 'Body not detected',
        isBodyVisible: false,
      });
    }

    if (!this._calibrated) {
      return new ExerciseStatus({
        primaryText: 'Calibrating',
        secondaryText: this._calibrationMessage,
        isBodyVisible: true,
      });
    }

    if (this._violationConfirmedThisEpisode && this._warningCount > 0) {
      const message = this._warningCount === 1
        ? 'FORM WARNING 1/2 — Return to the required position'
        : 'FORM WARNING 2/2 — One more form violation will end the test';
      return new ExerciseStatus({
        primaryText: message,
        secondaryText: `Reps: ${this._repCount}`,
        isBodyVisible: true,
      });
    }

    const formLabel = this._formStatus.toUpperCase();
    const formText = this._formReason ? `${formLabel} - ${this._formReason}` : formLabel;
    const advisoryText = this._formAdvisory ? `   •   ${this._formAdvisory}` : '';
    return new ExerciseStatus({
      primaryText: `Reps: ${this._repCount}`,
      secondaryText: `Form: ${formText}   •   Phase: ${this._phase}${advisoryText}`,
      isBodyVisible: true,
    });
  }
}
