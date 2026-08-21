/**
 * Vertical jump engine — simplified port of vertical_jump_engine.dart.
 *
 * 3 maximum-effort attempts, scored on best valid jump height.
 * Core rule: FEET decide events (takeoff/landing), HIP measures height.
 */
import { ExerciseEngine, ExerciseStatus } from './exerciseEngine.js';
import {
  isFullBodyVisible, averageHipY, averageHipX,
  leftAnkleY, rightAnkleY, averageAnkleY,
  estimateStandingHeightPixels, cmPerPixel, MIN_LANDMARK_VISIBILITY,
} from '../poseUtils.js';

const JState = Object.freeze({
  CALIBRATING: 'calibrating',
  READY: 'ready',
  AIRBORNE: 'airborne',
  AWAITING_BASELINE: 'awaitingBaseline',
  TEST_COMPLETE: 'testComplete',
});

class AnkleTracker {
  constructor() { this._window = []; this._lastSeen = null; }

  push(y, now, maxGapMs, windowSize) {
    if (y == null) return;
    if (this._lastSeen != null && now - this._lastSeen > maxGapMs) {
      this._window = [];
    }
    this._window.push({ time: now, y });
    if (this._window.length > windowSize) this._window.shift();
    this._lastSeen = now;
  }

  get rise() {
    if (this._window.length < 2) return null;
    return this._window[0].y - this._window[this._window.length - 1].y;
  }

  reset() { this._window = []; this._lastSeen = null; }
}

export class VerticalJumpEngine extends ExerciseEngine {
  constructor(userHeightCm) {
    super();
    this._userHeightCm = userHeightCm;
    this._maxAttempts = 3;
    this._setupInstruction =
      `Stand facing the camera with your entire body visible from head to feet. Hold still to calibrate, then perform up to ${this._maxAttempts} maximum-effort vertical jumps.`;
    this._stabilityWindowMs = 1300;
    this._ankleWindowSize = 4;
    this._maxAnkleGapMs = 250;
    this._ankleTakeoffRiseFraction = 0.04;
    this._takeoffPersistenceMs = 150;
    this._ankleLandingToleranceFraction = 0.15;
    this._landingDebounceMs = 180;
    this._maxAirborneMs = 2500;
    this._maxConsecutiveNotVisible = 10;
    this._horizontalDriftToleranceFraction = 0.25;
    this._calPositionToleranceFraction = 0.05;
    this._rearmMovementToleranceFraction = 0.05;
    this.reset();
  }

  reset() {
    this._state = JState.CALIBRATING;
    this._isBodyVisible = false;
    this._stableSince = null;
    this._calHipY = []; this._calHipX = [];
    this._calLeftAnkleY = []; this._calRightAnkleY = [];
    this._calStandingHeightPx = [];
    this._calRefHipY = null; this._calRefLeftAnkleY = null; this._calRefRightAnkleY = null;
    this._cmPerPixel = null;
    this._baselineHipY = null; this._baselineHipX = null;
    this._baselineLeftAnkleY = null; this._baselineRightAnkleY = null;
    this._bodyScalePx = 0;
    this._ankleTakeoffRisePx = 0;
    this._ankleLandingTolerancePx = 0;
    this._driftTolerancePx = 0;
    this._rearmTolerancePx = 0;
    this._leftAnkle = new AnkleTracker();
    this._rightAnkle = new AnkleTracker();
    this._takeoffCandidateSince = null;
    this._takeoffTime = null;
    this._airborneHipYSamples = [];
    this._maxAbsHipXDrift = 0;
    this._consecutiveNotVisible = 0;
    this._leftLandingSince = null; this._rightLandingSince = null;
    this._leftSettled = false; this._rightSettled = false;
    this._rearmStableSince = null;
    this._rearmRefHipY = null; this._rearmRefLeftAnkleY = null; this._rearmRefRightAnkleY = null;
    this._attempts = [];
  }

  get showPositionGuide() { return this._state === JState.CALIBRATING; }

  get groundGuideY() {
    const l = this._baselineLeftAnkleY;
    const r = this._baselineRightAnkleY;
    if (l == null || r == null) return null;
    return (l + r) / 2;
  }

  get bestValidHeightCm() {
    let best = null;
    for (const a of this._attempts) {
      if (a.isValid && a.heightCm != null && (best == null || a.heightCm > best)) {
        best = a.heightCm;
      }
    }
    return best;
  }

  processLandmarks(landmarks) {
    if (this._state === JState.TEST_COMPLETE) return;
    const now = Date.now();
    switch (this._state) {
      case JState.CALIBRATING: this._processCalibration(landmarks, now); break;
      case JState.READY: this._processReady(landmarks, now); break;
      case JState.AIRBORNE: this._processAirborne(landmarks, now); break;
      case JState.AWAITING_BASELINE: this._processAwaitingBaseline(landmarks, now); break;
    }
  }

  _processCalibration(landmarks, now) {
    const visible = landmarks && landmarks.length > 0 && isFullBodyVisible(landmarks);
    this._isBodyVisible = visible;
    if (!visible) { this._resetCalibrationWindow(); return; }

    const hipY = averageHipY(landmarks);
    const hipX = averageHipX(landmarks);
    const leftY = leftAnkleY(landmarks);
    const rightY = rightAnkleY(landmarks);
    if (hipY == null || hipX == null || leftY == null || rightY == null) {
      this._resetCalibrationWindow(); return;
    }

    if (this._calRefHipY == null) {
      this._calRefHipY = hipY; this._calRefLeftAnkleY = leftY; this._calRefRightAnkleY = rightY;
    } else {
      const frameBodyScale = ((leftY + rightY) / 2) - hipY;
      if (frameBodyScale > 0) {
        const tol = frameBodyScale * this._calPositionToleranceFraction;
        if (Math.abs(hipY - this._calRefHipY) > tol ||
            Math.abs(leftY - this._calRefLeftAnkleY) > tol ||
            Math.abs(rightY - this._calRefRightAnkleY) > tol) {
          this._resetCalibrationWindow();
          this._calRefHipY = hipY; this._calRefLeftAnkleY = leftY; this._calRefRightAnkleY = rightY;
        }
      }
    }

    if (!this._stableSince) this._stableSince = now;
    this._calHipY.push(hipY); this._calHipX.push(hipX);
    this._calLeftAnkleY.push(leftY); this._calRightAnkleY.push(rightY);
    const shp = estimateStandingHeightPixels(landmarks);
    if (shp != null && shp > 0) this._calStandingHeightPx.push(shp);

    if (now - this._stableSince < this._stabilityWindowMs) return;

    const avg = (arr) => arr.reduce((a, b) => a + b, 0) / arr.length;
    const avgHipY = avg(this._calHipY);
    const avgHipX = avg(this._calHipX);
    const avgLeftAnkleY = avg(this._calLeftAnkleY);
    const avgRightAnkleY = avg(this._calRightAnkleY);
    const bodyScale = ((avgLeftAnkleY + avgRightAnkleY) / 2) - avgHipY;
    if (bodyScale <= 0) { this._resetCalibrationWindow(); return; }

    const medianHeight = this._median(this._calStandingHeightPx);
    const cpp = medianHeight != null ? cmPerPixel(medianHeight, this._userHeightCm) : null;
    if (cpp == null) { this._resetCalibrationWindow(); return; }

    this._baselineHipY = avgHipY; this._baselineHipX = avgHipX;
    this._baselineLeftAnkleY = avgLeftAnkleY; this._baselineRightAnkleY = avgRightAnkleY;
    this._bodyScalePx = bodyScale;
    this._cmPerPixel = cpp;
    this._ankleTakeoffRisePx = bodyScale * this._ankleTakeoffRiseFraction;
    this._ankleLandingTolerancePx = bodyScale * this._ankleLandingToleranceFraction;
    this._driftTolerancePx = bodyScale * this._horizontalDriftToleranceFraction;
    this._rearmTolerancePx = bodyScale * this._rearmMovementToleranceFraction;
    this._state = JState.READY;
  }

  _processReady(landmarks, now) {
    const leftY = landmarks ? leftAnkleY(landmarks) : null;
    const rightY = landmarks ? rightAnkleY(landmarks) : null;
    const hipY = landmarks ? averageHipY(landmarks) : null;
    this._isBodyVisible = leftY != null || rightY != null || hipY != null;

    this._leftAnkle.push(leftY, now, this._maxAnkleGapMs, this._ankleWindowSize);
    this._rightAnkle.push(rightY, now, this._maxAnkleGapMs, this._ankleWindowSize);

    const leftRise = this._leftAnkle.rise;
    const rightRise = this._rightAnkle.rise;
    const bothRising = leftRise != null && rightRise != null &&
      leftRise >= this._ankleTakeoffRisePx && rightRise >= this._ankleTakeoffRisePx;

    if (!bothRising) { this._takeoffCandidateSince = null; return; }

    if (!this._takeoffCandidateSince) this._takeoffCandidateSince = now;
    if (now - this._takeoffCandidateSince >= this._takeoffPersistenceMs) {
      this._state = JState.AIRBORNE;
      this._takeoffTime = this._takeoffCandidateSince;
      this._leftAnkle.reset(); this._rightAnkle.reset();
      this._airborneHipYSamples = [];
      this._maxAbsHipXDrift = 0;
      this._consecutiveNotVisible = 0;
      this._leftLandingSince = null; this._rightLandingSince = null;
      this._leftSettled = false; this._rightSettled = false;
    }
  }

  _processAirborne(landmarks, now) {
    const hipY = landmarks ? averageHipY(landmarks) : null;
    const hipX = landmarks ? averageHipX(landmarks) : null;
    const leftY = landmarks ? leftAnkleY(landmarks) : null;
    const rightY = landmarks ? rightAnkleY(landmarks) : null;

    const anySignal = hipY != null || leftY != null || rightY != null;
    this._isBodyVisible = anySignal;
    if (anySignal) { this._consecutiveNotVisible = 0; }
    else {
      this._consecutiveNotVisible++;
      if (this._consecutiveNotVisible > this._maxConsecutiveNotVisible) {
        this._finalizeAttempt('insufficientData'); return;
      }
    }

    if (hipY != null) this._airborneHipYSamples.push(hipY);
    if (hipX != null) {
      const drift = Math.abs(hipX - this._baselineHipX);
      if (drift > this._maxAbsHipXDrift) this._maxAbsHipXDrift = drift;
    }

    // Landing detection per foot
    if (!this._leftSettled && leftY != null) {
      if ((this._baselineLeftAnkleY - leftY) <= this._ankleLandingTolerancePx) {
        if (!this._leftLandingSince) this._leftLandingSince = now;
        if (now - this._leftLandingSince >= this._landingDebounceMs) this._leftSettled = true;
      } else { this._leftLandingSince = null; }
    }
    if (!this._rightSettled && rightY != null) {
      if ((this._baselineRightAnkleY - rightY) <= this._ankleLandingTolerancePx) {
        if (!this._rightLandingSince) this._rightLandingSince = now;
        if (now - this._rightLandingSince >= this._landingDebounceMs) this._rightSettled = true;
      } else { this._rightLandingSince = null; }
    }

    if (this._leftSettled && this._rightSettled) {
      this._finalizeAttempt(); return;
    }

    if (now - this._takeoffTime >= this._maxAirborneMs) {
      this._finalizeAttempt('insufficientData'); return;
    }
  }

  _processAwaitingBaseline(landmarks, now) {
    const hipY = landmarks ? averageHipY(landmarks) : null;
    const leftY = landmarks ? leftAnkleY(landmarks) : null;
    const rightY = landmarks ? rightAnkleY(landmarks) : null;
    this._isBodyVisible = hipY != null || leftY != null || rightY != null;

    if (hipY == null || leftY == null || rightY == null) {
      this._rearmStableSince = null;
      this._rearmRefHipY = null;
      return;
    }

    if (this._rearmRefHipY == null) {
      this._rearmRefHipY = hipY;
      this._rearmRefLeftAnkleY = leftY;
      this._rearmRefRightAnkleY = rightY;
      this._rearmStableSince = now;
      return;
    }

    if (Math.abs(hipY - this._rearmRefHipY) > this._rearmTolerancePx ||
        Math.abs(leftY - this._rearmRefLeftAnkleY) > this._rearmTolerancePx ||
        Math.abs(rightY - this._rearmRefRightAnkleY) > this._rearmTolerancePx) {
      this._rearmRefHipY = hipY;
      this._rearmRefLeftAnkleY = leftY;
      this._rearmRefRightAnkleY = rightY;
      this._rearmStableSince = now;
      return;
    }

    if (!this._rearmStableSince) this._rearmStableSince = now;
    if (now - this._rearmStableSince >= this._stabilityWindowMs) {
      this._state = JState.READY;
      this._leftAnkle.reset(); this._rightAnkle.reset();
      this._takeoffCandidateSince = null;
    }
  }

  _finalizeAttempt(forcedReason = null) {
    const attemptNum = this._attempts.length + 1;

    if (forcedReason) {
      this._attempts.push({ attemptNumber: attemptNum, isValid: false, invalidReason: forcedReason, heightCm: null });
    } else if (this._airborneHipYSamples.length === 0) {
      this._attempts.push({ attemptNumber: attemptNum, isValid: false, invalidReason: 'insufficientData', heightCm: null });
    } else if (this._maxAbsHipXDrift > this._driftTolerancePx) {
      this._attempts.push({ attemptNumber: attemptNum, isValid: false, invalidReason: 'excessiveDrift', heightCm: null });
    } else {
      const apexHipY = this._robustApex(this._airborneHipYSamples);
      const displacementPx = this._baselineHipY - apexHipY;
      const heightCm = displacementPx > 0 ? displacementPx * this._cmPerPixel : 0;
      this._attempts.push({ attemptNumber: attemptNum, isValid: true, heightCm: Math.round(heightCm * 10) / 10 });
    }

    if (this._attempts.length >= this._maxAttempts) {
      this._state = JState.TEST_COMPLETE;
    } else {
      this._state = JState.AWAITING_BASELINE;
      this._rearmStableSince = null;
      this._rearmRefHipY = null;
    }
  }

  _robustApex(samples) {
    let minIdx = 0;
    for (let i = 1; i < samples.length; i++) {
      if (samples[i] < samples[minIdx]) minIdx = i;
    }
    const r = 2;
    const start = Math.max(0, minIdx - r);
    const end = Math.min(samples.length - 1, minIdx + r);
    return this._median(samples.slice(start, end + 1));
  }

  _median(arr) {
    if (!arr || arr.length === 0) return null;
    const sorted = [...arr].sort((a, b) => a - b);
    const mid = Math.floor(sorted.length / 2);
    return sorted.length % 2 !== 0 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
  }

  _resetCalibrationWindow() {
    this._stableSince = null;
    this._calHipY = []; this._calHipX = [];
    this._calLeftAnkleY = []; this._calRightAnkleY = [];
    this._calStandingHeightPx = [];
    this._calRefHipY = null; this._calRefLeftAnkleY = null; this._calRefRightAnkleY = null;
  }

  get status() {
    const best = this.bestValidHeightCm;
    const bestText = best != null ? ` | Best: ${best} cm` : '';

    switch (this._state) {
      case JState.CALIBRATING:
        if (!this._isBodyVisible) {
          return new ExerciseStatus({
            primaryText: this._setupInstruction,
            secondaryText: 'Body not detected',
            isBodyVisible: false,
          });
        }
        if (!this._stableSince) {
          return new ExerciseStatus({
            primaryText: 'Stand still to calibrate',
            secondaryText: 'Keep your entire body visible',
            isBodyVisible: true,
          });
        }
        return new ExerciseStatus({
          primaryText: 'Calibrating...',
          secondaryText: `Hold still (${Math.min(100, Math.round(((Date.now() - this._stableSince) / this._stabilityWindowMs) * 100))}%)`,
          isBodyVisible: true,
        });

      case JState.READY:
        return new ExerciseStatus({
          primaryText: `Ready - Jump! (${this._attempts.length}/${this._maxAttempts})${bestText}`,
          secondaryText: 'Jump straight up when ready',
          isBodyVisible: this._isBodyVisible,
        });

      case JState.AIRBORNE:
        return new ExerciseStatus({
          primaryText: 'Airborne!',
          secondaryText: 'Tracking jump...',
          isBodyVisible: this._isBodyVisible,
        });

      case JState.AWAITING_BASELINE: {
        const lastAttempt = this._attempts[this._attempts.length - 1];
        const lastText = lastAttempt?.isValid
          ? `Last jump: ${lastAttempt.heightCm} cm`
          : `Last jump: Invalid (${lastAttempt?.invalidReason})`;
        return new ExerciseStatus({
          primaryText: `${lastText}${bestText}`,
          secondaryText: 'Stand still for next attempt...',
          isBodyVisible: this._isBodyVisible,
        });
      }

      case JState.TEST_COMPLETE:
        return new ExerciseStatus({
          primaryText: best != null ? `Test Complete! Best: ${best} cm` : 'Test Complete - No valid jumps',
          secondaryText: this._attempts.map((a, i) =>
            a.isValid ? `#${i + 1}: ${a.heightCm} cm` : `#${i + 1}: Invalid`
          ).join('   •   '),
          isBodyVisible: this._isBodyVisible,
        });
    }
  }
}
