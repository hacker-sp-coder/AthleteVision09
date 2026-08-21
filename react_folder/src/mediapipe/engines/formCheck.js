/**
 * Form validation checks — ported from form_check.dart.
 *
 * Each check is a composable validation primitive that evaluates a single
 * aspect of the athlete's pose (visibility, orientation, angle range, etc.)
 * and returns VALID / INVALID / UNCERTAIN.
 */
import { angleBetweenPoints, pixelDistance, isLandmarkVisible, MIN_LANDMARK_VISIBILITY } from '../poseUtils.js';
import { BodyPoint, resolveSidedPose, otherShoulderIndex } from '../sidedPose.js';

// ─── Enums & Value Objects ───────────────────────────────────────────────

export const CheckStatus = Object.freeze({
  VALID: 'valid',
  INVALID: 'invalid',
  UNCERTAIN: 'uncertain',
});

export class FormCheckResult {
  constructor(status, reason) {
    this.status = status;
    this.reason = reason;
  }

  static OK = new FormCheckResult(CheckStatus.VALID, '');
}

/** Calibrated athlete-specific baseline, keyed by reference key. */
export class ExerciseReference {
  constructor(values = {}) {
    this.values = values;
  }
  get(key) { return this.values[key] ?? null; }
}

/**
 * Context passed to every FormCheck on every frame.
 * @typedef {Object} FormCheckContext
 * @property {Array} landmarks  Raw MediaPipe landmarks array
 * @property {import('../sidedPose.js').SidedPose|null} sidedPose
 * @property {ExerciseReference|null} reference
 */

// ─── FormCheck Base ──────────────────────────────────────────────────────

export class FormCheck {
  get name() { return 'base'; }

  /** @param {FormCheckContext} ctx @returns {FormCheckResult} */
  evaluate(_ctx) { return FormCheckResult.OK; }

  /** Key this check stores its calibrated baseline under, or null. */
  get referenceKey() { return null; }

  /** Raw value for referenceKey this frame, sampled during calibration. */
  sampleValue(_ctx) { return null; }
}

// ─── Concrete Checks ─────────────────────────────────────────────────────

/**
 * Gate #1: do we have enough confidently-visible landmarks?
 */
export class RequiredLandmarksCheck extends FormCheck {
  get name() { return 'required_landmarks'; }

  evaluate(ctx) {
    if (!ctx.sidedPose) {
      return new FormCheckResult(CheckStatus.UNCERTAIN, 'Move into frame - keep your whole body visible');
    }
    return FormCheckResult.OK;
  }
}

/**
 * Coarse side-on-ness check: shoulder-width / torso-length ratio.
 */
export class SideOrientationCheck extends FormCheck {
  constructor({ maxShoulderRatio = 0.55, minOtherShoulderVisibility = 0.3 } = {}) {
    super();
    this._maxRatio = maxShoulderRatio;
    this._minOtherVis = minOtherShoulderVisibility;
  }

  get name() { return 'side_orientation'; }

  evaluate(ctx) {
    const sided = ctx.sidedPose;
    const shoulder = sided?.points[BodyPoint.SHOULDER];
    const hip = sided?.points[BodyPoint.HIP];
    if (!sided || !shoulder || !hip) {
      return new FormCheckResult(CheckStatus.UNCERTAIN, 'Move into frame');
    }

    const otherIdx = otherShoulderIndex(sided.isLeftSide);
    const other = ctx.landmarks[otherIdx];
    if (!other || (other.visibility ?? 0) < this._minOtherVis) {
      return new FormCheckResult(CheckStatus.UNCERTAIN, 'Turn sideways so one shoulder is hidden behind the other');
    }

    const torsoLength = pixelDistance(shoulder, hip);
    if (torsoLength <= 0) {
      return new FormCheckResult(CheckStatus.UNCERTAIN, 'Move into frame');
    }

    const ratio = pixelDistance(shoulder, other) / torsoLength;
    if (ratio > this._maxRatio) {
      return new FormCheckResult(CheckStatus.INVALID, 'Turn more sideways to the camera');
    }
    return FormCheckResult.OK;
  }
}

/**
 * Body-line inclination from horizontal (push-up plank, supine crunch).
 */
export class BodyInclinationCheck extends FormCheck {
  constructor({
    from = BodyPoint.SHOULDER,
    to = BodyPoint.ANKLE,
    maxInclinationFromHorizontalDeg = 40,
    invalidReason = 'Get into a horizontal push-up plank position',
  } = {}) {
    super();
    this._from = from;
    this._to = to;
    this._maxIncl = maxInclinationFromHorizontalDeg;
    this._reason = invalidReason;
  }

  get name() { return 'body_inclination'; }

  _inclinationDeg(ctx) {
    const sided = ctx.sidedPose;
    if (!sided) return null;
    const a = sided.points[this._from];
    const b = sided.points[this._to];
    if (!a || !b) return null;
    const dx = Math.abs(b.x - a.x);
    const dy = Math.abs(b.y - a.y);
    if (dx === 0 && dy === 0) return 90;
    return Math.atan2(dy, dx) * (180 / Math.PI);
  }

  evaluate(ctx) {
    const incl = this._inclinationDeg(ctx);
    if (incl == null) return new FormCheckResult(CheckStatus.UNCERTAIN, 'Body line not visible');
    if (incl > this._maxIncl) return new FormCheckResult(CheckStatus.INVALID, this._reason);
    return FormCheckResult.OK;
  }
}

/**
 * Broad plausibility floor/ceiling on a joint angle.
 */
export class AngleRangeCheck extends FormCheck {
  constructor({ landmarks, minDeg = 50, maxDeg = 180 }) {
    super();
    this._landmarks = landmarks; // [BodyPoint, BodyPoint, BodyPoint]
    this._min = minDeg;
    this._max = maxDeg;
  }

  get name() { return 'angle_range'; }

  _angle(ctx) {
    const sided = ctx.sidedPose;
    if (!sided) return null;
    const [a, b, c] = this._landmarks;
    const pa = sided.points[a];
    const pb = sided.points[b];
    const pc = sided.points[c];
    if (!pa || !pb || !pc) return null;
    return angleBetweenPoints(pa, pb, pc);
  }

  evaluate(ctx) {
    const angle = this._angle(ctx);
    if (angle == null) return new FormCheckResult(CheckStatus.UNCERTAIN, 'Move into frame');
    if (angle < this._min || angle > this._max) {
      return new FormCheckResult(CheckStatus.INVALID, 'Joint angle looks implausible - reposition');
    }
    return FormCheckResult.OK;
  }
}

/**
 * Body-line straightness (e.g. shoulder-hip-ankle). Reference-aware.
 */
export class BodyRigidityCheck extends FormCheck {
  constructor({ a, b, c, absoluteMinDeg = 155, toleranceDeg = 18 }) {
    super();
    this._a = a; this._b = b; this._c = c;
    this._absMin = absoluteMinDeg;
    this._tol = toleranceDeg;
  }

  get name() { return 'body_rigidity'; }
  get referenceKey() { return 'bodyRigidityAngleDeg'; }

  _angle(ctx) {
    const sided = ctx.sidedPose;
    if (!sided) return null;
    const pa = sided.points[this._a];
    const pb = sided.points[this._b];
    const pc = sided.points[this._c];
    if (!pa || !pb || !pc) return null;
    return angleBetweenPoints(pa, pb, pc);
  }

  sampleValue(ctx) { return this._angle(ctx); }

  evaluate(ctx) {
    const angle = this._angle(ctx);
    if (angle == null) return new FormCheckResult(CheckStatus.UNCERTAIN, 'Body line not visible');
    const ref = ctx.reference?.get(this.referenceKey);
    const broken = ref != null ? Math.abs(angle - ref) > this._tol : angle < this._absMin;
    if (broken) return new FormCheckResult(CheckStatus.INVALID, 'Keep your body straight - avoid hip sag or pike');
    return FormCheckResult.OK;
  }
}

/**
 * Torso-lean constraint (shoulder-hip line vs true vertical).
 */
export class TorsoOrientationCheck extends FormCheck {
  constructor({ from = BodyPoint.SHOULDER, to = BodyPoint.HIP, maxLeanFromVerticalDeg = 45 } = {}) {
    super();
    this._from = from; this._to = to;
    this._maxLean = maxLeanFromVerticalDeg;
  }

  get name() { return 'torso_orientation'; }

  _leanDeg(ctx) {
    const sided = ctx.sidedPose;
    if (!sided) return null;
    const a = sided.points[this._from];
    const b = sided.points[this._to];
    if (!a || !b) return null;
    const dx = Math.abs(b.x - a.x);
    const dy = Math.abs(b.y - a.y);
    if (dx === 0 && dy === 0) return 0;
    return Math.atan2(dx, dy) * (180 / Math.PI);
  }

  evaluate(ctx) {
    const lean = this._leanDeg(ctx);
    if (lean == null) return new FormCheckResult(CheckStatus.UNCERTAIN, 'Torso not visible');
    if (lean > this._maxLean) return new FormCheckResult(CheckStatus.INVALID, 'Keep your torso more upright - avoid folding forward');
    return FormCheckResult.OK;
  }
}

/**
 * Gates calibration on the primary movement angle.
 */
export class CalibrationAngleGateCheck extends FormCheck {
  constructor({ landmarks, minDeg = null, maxDeg = null, failureReason }) {
    super();
    this._landmarks = landmarks;
    this._min = minDeg; this._max = maxDeg;
    this._reason = failureReason;
  }

  get name() { return 'calibration_angle_gate'; }

  _angle(ctx) {
    const sided = ctx.sidedPose;
    if (!sided) return null;
    const [a, b, c] = this._landmarks;
    const pa = sided.points[a]; const pb = sided.points[b]; const pc = sided.points[c];
    if (!pa || !pb || !pc) return null;
    return angleBetweenPoints(pa, pb, pc);
  }

  evaluate(ctx) {
    if (ctx.reference) return FormCheckResult.OK;
    const angle = this._angle(ctx);
    if (angle == null) return new FormCheckResult(CheckStatus.UNCERTAIN, 'Move into frame');
    if ((this._min != null && angle < this._min) || (this._max != null && angle > this._max)) {
      return new FormCheckResult(CheckStatus.INVALID, this._reason);
    }
    return FormCheckResult.OK;
  }
}

/**
 * Limb extension check (hip-knee-ankle for legs, shoulder-elbow-wrist for arms).
 * Reference-aware like BodyRigidityCheck.
 */
export class LegExtensionCheck extends FormCheck {
  constructor({
    a = BodyPoint.HIP, b = BodyPoint.KNEE, c = BodyPoint.ANKLE,
    absoluteMinDeg = 150, toleranceDeg = 20,
    key = 'legExtensionAngleDeg', checkName = 'leg_extension',
    notVisibleReason = 'Legs not visible',
    invalidReason = 'Keep your legs straight - do not drop to your knees',
  } = {}) {
    super();
    this._a = a; this._b = b; this._c = c;
    this._absMin = absoluteMinDeg; this._tol = toleranceDeg;
    this._key = key; this._checkName = checkName;
    this._notVis = notVisibleReason; this._invalid = invalidReason;
  }

  get name() { return this._checkName; }
  get referenceKey() { return this._key; }

  _angle(ctx) {
    const sided = ctx.sidedPose;
    if (!sided) return null;
    const pa = sided.points[this._a]; const pb = sided.points[this._b]; const pc = sided.points[this._c];
    if (!pa || !pb || !pc) return null;
    return angleBetweenPoints(pa, pb, pc);
  }

  sampleValue(ctx) { return this._angle(ctx); }

  evaluate(ctx) {
    const angle = this._angle(ctx);
    if (angle == null) return new FormCheckResult(CheckStatus.UNCERTAIN, this._notVis);
    const ref = ctx.reference?.get(this.referenceKey);
    const broken = ref != null ? Math.abs(angle - ref) > this._tol : angle < this._absMin;
    if (broken) return new FormCheckResult(CheckStatus.INVALID, this._invalid);
    return FormCheckResult.OK;
  }
}

/**
 * Captures vertical-position baseline during calibration.
 */
export class VerticalBaselineReferenceCheck extends FormCheck {
  constructor({ key, sampler, checkName = 'vertical_baseline_reference' }) {
    super();
    this._key = key;
    this._sampler = sampler; // (landmarks) => number|null
    this._checkName = checkName;
  }

  get name() { return this._checkName; }
  get referenceKey() { return this._key; }

  sampleValue(ctx) { return this._sampler(ctx.landmarks); }

  evaluate(ctx) {
    if (this._sampler(ctx.landmarks) == null) {
      return new FormCheckResult(CheckStatus.UNCERTAIN, 'Move into frame');
    }
    return FormCheckResult.OK;
  }
}

/**
 * Captures a joint-angle baseline during calibration.
 */
export class AngleBaselineReferenceCheck extends FormCheck {
  constructor({ landmarks, key, checkName = 'angle_baseline_reference' }) {
    super();
    this._landmarks = landmarks;
    this._key = key;
    this._checkName = checkName;
  }

  get name() { return this._checkName; }
  get referenceKey() { return this._key; }

  _angle(ctx) {
    const sided = ctx.sidedPose;
    if (!sided) return null;
    const [a, b, c] = this._landmarks;
    const pa = sided.points[a]; const pb = sided.points[b]; const pc = sided.points[c];
    if (!pa || !pb || !pc) return null;
    return angleBetweenPoints(pa, pb, pc);
  }

  sampleValue(ctx) { return this._angle(ctx); }

  evaluate(ctx) {
    if (this._angle(ctx) == null) {
      return new FormCheckResult(CheckStatus.UNCERTAIN, 'Move into frame');
    }
    return FormCheckResult.OK;
  }
}

/**
 * Captures body-scale reference (pixel distance) during calibration.
 */
export class ScaleReferenceCheck extends FormCheck {
  constructor({ a, b, key = 'scaleReferencePx' }) {
    super();
    this._a = a; this._b = b; this._key = key;
  }

  get name() { return 'scale_reference'; }
  get referenceKey() { return this._key; }

  _distance(ctx) {
    const sided = ctx.sidedPose;
    if (!sided) return null;
    const pa = sided.points[this._a]; const pb = sided.points[this._b];
    if (!pa || !pb) return null;
    return pixelDistance(pa, pb);
  }

  sampleValue(ctx) { return this._distance(ctx); }

  evaluate(ctx) {
    if (this._distance(ctx) == null) {
      return new FormCheckResult(CheckStatus.UNCERTAIN, 'Move into frame');
    }
    return FormCheckResult.OK;
  }
}

// ─── Bottom Event Validation (Squat depth check) ─────────────────────────

export const BottomEventOutcome = Object.freeze({
  NO_QUALIFYING_ATTEMPT: 'noQualifyingAttempt',
  INSUFFICIENT_DEPTH: 'insufficientDepth',
  FORM_VIOLATION: 'formViolation',
  UNCERTAIN: 'uncertain',
  VALID: 'valid',
});

export class BottomEventResult {
  constructor(outcome, reason) {
    this.outcome = outcome;
    this.reason = reason;
  }
  static OK = new BottomEventResult(BottomEventOutcome.VALID, '');
}

/**
 * Validates that a BOTTOM event represents genuine hip displacement.
 */
export class HipDisplacementValidator {
  constructor({
    hipBaselineKey = 'hipBaselineY',
    shoulderBaselineKey = 'shoulderBaselineY',
    scaleReferenceKey = 'scaleReferencePx',
    minQualifyingNormalizedHipDisplacement = 0.18,
    minNormalizedHipDisplacement = 0.30,
    maxShoulderToHipDisplacementRatio = 2.5,
  } = {}) {
    this._hipKey = hipBaselineKey;
    this._shoulderKey = shoulderBaselineKey;
    this._scaleKey = scaleReferenceKey;
    this._minQualifying = minQualifyingNormalizedHipDisplacement;
    this._minDepth = minNormalizedHipDisplacement;
    this._maxRatio = maxShoulderToHipDisplacementRatio;
  }

  validate(ctx) {
    const hipBaseline = ctx.reference.get(this._hipKey);
    const shoulderBaseline = ctx.reference.get(this._shoulderKey);
    const scaleRef = ctx.reference.get(this._scaleKey);

    if (hipBaseline == null || shoulderBaseline == null || scaleRef == null || scaleRef <= 0
        || ctx.hipYSamples.length === 0 || ctx.shoulderYSamples.length === 0) {
      return new BottomEventResult(BottomEventOutcome.UNCERTAIN, 'Movement reference unavailable');
    }

    const avg = (arr) => arr.reduce((a, b) => a + b, 0) / arr.length;
    const bottomHipY = avg(ctx.hipYSamples);
    const bottomShoulderY = avg(ctx.shoulderYSamples);

    const hipDisplacement = bottomHipY - hipBaseline;
    const shoulderDisplacement = bottomShoulderY - shoulderBaseline;
    const normalizedHipDisplacement = hipDisplacement / scaleRef;

    if (normalizedHipDisplacement < this._minQualifying) {
      return new BottomEventResult(BottomEventOutcome.NO_QUALIFYING_ATTEMPT, 'No qualifying squat movement detected');
    }
    if (normalizedHipDisplacement < this._minDepth) {
      return new BottomEventResult(BottomEventOutcome.INSUFFICIENT_DEPTH, 'Squat depth not reached - lower your hips further');
    }
    if (shoulderDisplacement > hipDisplacement * this._maxRatio) {
      return new BottomEventResult(BottomEventOutcome.FORM_VIOLATION, 'Bend at the hips and knees - do not just fold your upper body forward');
    }
    return BottomEventResult.OK;
  }
}
