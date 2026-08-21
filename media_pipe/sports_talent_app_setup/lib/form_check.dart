import 'dart:math' as math;

import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import 'pose_utils.dart';
import 'sided_pose.dart';

enum CheckStatus { valid, invalid, uncertain }

class FormCheckResult {
  const FormCheckResult(this.status, this.reason);

  static const ok = FormCheckResult(CheckStatus.valid, '');

  final CheckStatus status;
  final String reason;
}

/// An athlete-specific normalized baseline captured during calibration,
/// keyed by each [FormCheck]'s own [FormCheck.referenceKey].
class ExerciseReference {
  const ExerciseReference(this.values);

  final Map<String, double> values;

  double? get(String key) => values[key];
}

class FormCheckContext {
  const FormCheckContext({required this.pose, required this.sidedPose, this.reference});

  final Pose pose;
  final SidedPose? sidedPose;

  /// Null before calibration locks in.
  final ExerciseReference? reference;
}

/// A small composable validation primitive: given the current pose (and,
/// once calibrated, the athlete's own reference envelope), decide whether
/// this frame is VALID, a definite INVALID violation, or UNCERTAIN (not
/// enough reliable information to judge either way).
abstract class FormCheck {
  const FormCheck();

  String get name;

  FormCheckResult evaluate(FormCheckContext context);

  /// Key this check stores its calibrated baseline under, or null if it
  /// doesn't need a reference value (e.g. purely structural/coarse checks).
  String? get referenceKey => null;

  /// This frame's raw value for [referenceKey], sampled during the
  /// calibration stability window and averaged by the engine. Null if
  /// unavailable this frame.
  double? sampleValue(FormCheckContext context) => null;
}

/// Gate #1: do we have enough confidently-visible landmarks to say anything
/// at all? [resolveSidedPose] already enforces the per-landmark confidence
/// threshold; this check just names the condition for calibration/UI.
class RequiredLandmarksCheck extends FormCheck {
  const RequiredLandmarksCheck();

  @override
  String get name => 'required_landmarks';

  @override
  FormCheckResult evaluate(FormCheckContext context) {
    if (context.sidedPose == null) {
      return const FormCheckResult(
        CheckStatus.uncertain,
        'Move into frame - keep your whole body visible',
      );
    }
    return FormCheckResult.ok;
  }
}

/// Coarse, fixed-threshold side-on-ness check: shoulder-width / torso-length
/// on screen. In a true side view the shoulders nearly overlap, so this
/// ratio stays low. Deliberately simple - not a sophisticated orientation
/// classifier, and not reference-relative.
class SideOrientationCheck extends FormCheck {
  const SideOrientationCheck({
    this.maxShoulderRatio = 0.55,
    this.minOtherShoulderLikelihood = 0.3,
  });

  final double maxShoulderRatio;

  /// Likelihood floor for the far shoulder - deliberately looser than the
  /// strict per-landmark threshold, since that shoulder is expected to be
  /// partly occluded in good side-on form (that's UNCERTAIN, not INVALID).
  final double minOtherShoulderLikelihood;

  @override
  String get name => 'side_orientation';

  @override
  FormCheckResult evaluate(FormCheckContext context) {
    final sided = context.sidedPose;
    final shoulder = sided?[BodyPoint.shoulder];
    final hip = sided?[BodyPoint.hip];
    if (sided == null || shoulder == null || hip == null) {
      return const FormCheckResult(CheckStatus.uncertain, 'Move into frame');
    }

    final otherType = sided.isLeftSide
        ? PoseLandmarkType.rightShoulder
        : PoseLandmarkType.leftShoulder;
    final other = context.pose.landmarks[otherType];
    if (other == null || other.likelihood < minOtherShoulderLikelihood) {
      return const FormCheckResult(
        CheckStatus.uncertain,
        'Turn sideways so one shoulder is hidden behind the other',
      );
    }

    final torsoLength = pixelDistance(shoulder, hip);
    if (torsoLength <= 0) {
      return const FormCheckResult(CheckStatus.uncertain, 'Move into frame');
    }

    final ratio = pixelDistance(shoulder, other) / torsoLength;
    if (ratio > maxShoulderRatio) {
      return const FormCheckResult(CheckStatus.invalid, 'Turn more sideways to the camera');
    }
    return FormCheckResult.ok;
  }
}

/// Is the (straight) body line oriented approximately horizontally, rather
/// than upright? Distinct from [BodyRigidityCheck], which only asks whether
/// the line is straight, not which way it's pointing - a standing side-on
/// person can have a perfectly straight, fully side-on shoulder-hip-ankle
/// line that's still vertical, which this check exists to reject. Fixed
/// threshold in both calibration and continuous tracking (not
/// reference-relative) - used both to require a Push-up plank stay roughly
/// horizontal throughout the whole rep, and (with shoulder->hip landmarks)
/// as Controlled Crunch's posture gate, rejecting a standing torso in favor
/// of a genuine supine starting position, before calibration is allowed to
/// begin or continue.
class BodyInclinationCheck extends FormCheck {
  const BodyInclinationCheck({
    this.from = BodyPoint.shoulder,
    this.to = BodyPoint.ankle,
    this.maxInclinationFromHorizontalDeg = 40,
    this.invalidReason = 'Get into a horizontal push-up plank position',
  });

  final BodyPoint from;
  final BodyPoint to;
  final double maxInclinationFromHorizontalDeg;

  /// Message shown when the line's inclination exceeds
  /// [maxInclinationFromHorizontalDeg]. Configurable per use (e.g. a
  /// Push-up plank vs. a Controlled Crunch supine posture) since the same
  /// geometric violation means something different for each exercise.
  final String invalidReason;

  @override
  String get name => 'body_inclination';

  /// Angle of the [from]->[to] line from horizontal, normalized to [0,90]:
  /// 0 = perfectly horizontal, 90 = perfectly vertical.
  double? _inclinationDeg(FormCheckContext context) {
    final sided = context.sidedPose;
    if (sided == null) return null;
    final a = sided[from];
    final b = sided[to];
    if (a == null || b == null) return null;
    final dx = (b.x - a.x).abs();
    final dy = (b.y - a.y).abs();
    if (dx == 0 && dy == 0) return 90;
    return math.atan2(dy, dx) * 180 / math.pi;
  }

  @override
  FormCheckResult evaluate(FormCheckContext context) {
    final inclination = _inclinationDeg(context);
    if (inclination == null) {
      return const FormCheckResult(CheckStatus.uncertain, 'Body line not visible');
    }
    if (inclination > maxInclinationFromHorizontalDeg) {
      return FormCheckResult(CheckStatus.invalid, invalidReason);
    }
    return FormCheckResult.ok;
  }
}

/// Broad plausibility floor/ceiling on a joint angle - a defensive sanity
/// check, independent of (and much looser than) the tight top/bottom
/// thresholds that actually drive the rep-cycle state machine.
class AngleRangeCheck extends FormCheck {
  const AngleRangeCheck({required this.landmarks, this.minDeg = 50, this.maxDeg = 180});

  final (BodyPoint, BodyPoint, BodyPoint) landmarks;
  final double minDeg;
  final double maxDeg;

  @override
  String get name => 'angle_range';

  double? _angle(FormCheckContext context) {
    final sided = context.sidedPose;
    if (sided == null) return null;
    final (a, b, c) = landmarks;
    final pa = sided[a];
    final pb = sided[b];
    final pc = sided[c];
    if (pa == null || pb == null || pc == null) return null;
    return angleBetweenPoints(pa, pb, pc);
  }

  @override
  FormCheckResult evaluate(FormCheckContext context) {
    final angle = _angle(context);
    if (angle == null) {
      return const FormCheckResult(CheckStatus.uncertain, 'Move into frame');
    }
    if (angle < minDeg || angle > maxDeg) {
      return const FormCheckResult(
        CheckStatus.invalid,
        'Joint angle looks implausible - reposition',
      );
    }
    return FormCheckResult.ok;
  }
}

/// Body-line straightness (e.g. shoulder-hip-ankle). The one reference-aware
/// check: during calibration (no reference yet) it uses a fixed absolute
/// floor; once calibrated, it compares against the athlete's own calibrated
/// angle with a tolerance band instead of a global constant.
class BodyRigidityCheck extends FormCheck {
  const BodyRigidityCheck({
    required this.a,
    required this.b,
    required this.c,
    this.absoluteMinDeg = 155,
    this.toleranceDeg = 18,
  });

  final BodyPoint a;
  final BodyPoint b;
  final BodyPoint c;
  final double absoluteMinDeg;
  final double toleranceDeg;

  @override
  String get name => 'body_rigidity';

  @override
  String? get referenceKey => 'bodyRigidityAngleDeg';

  double? _angle(FormCheckContext context) {
    final sided = context.sidedPose;
    if (sided == null) return null;
    final pa = sided[a];
    final pb = sided[b];
    final pc = sided[c];
    if (pa == null || pb == null || pc == null) return null;
    return angleBetweenPoints(pa, pb, pc);
  }

  @override
  double? sampleValue(FormCheckContext context) => _angle(context);

  @override
  FormCheckResult evaluate(FormCheckContext context) {
    final angle = _angle(context);
    if (angle == null) {
      return const FormCheckResult(CheckStatus.uncertain, 'Body line not visible');
    }

    final reference = context.reference?.get(referenceKey!);
    final broken = reference != null
        ? (angle - reference).abs() > toleranceDeg
        : angle < absoluteMinDeg;

    if (broken) {
      return const FormCheckResult(
        CheckStatus.invalid,
        'Keep your body straight - avoid hip sag or pike',
      );
    }
    return FormCheckResult.ok;
  }
}

/// Torso-lean constraint (shoulder-hip line vs. true vertical). Unlike
/// [BodyInclinationCheck] (which enforces near-horizontal for a push-up
/// plank), this rejects only a *clearly abnormal* torso orientation while
/// allowing the moderate forward lean that's a normal part of a squat.
/// Fixed threshold, evaluated continuously (calibration and tracking alike)
/// since excessive lean is unacceptable at any point in the rep.
class TorsoOrientationCheck extends FormCheck {
  const TorsoOrientationCheck({
    this.from = BodyPoint.shoulder,
    this.to = BodyPoint.hip,
    this.maxLeanFromVerticalDeg = 45,
  });

  final BodyPoint from;
  final BodyPoint to;
  final double maxLeanFromVerticalDeg;

  @override
  String get name => 'torso_orientation';

  /// Angle of the [from]->[to] line from true vertical, normalized to
  /// [0,90]: 0 = perfectly vertical (standing tall), 90 = perfectly
  /// horizontal (bent fully over).
  double? _leanFromVerticalDeg(FormCheckContext context) {
    final sided = context.sidedPose;
    if (sided == null) return null;
    final a = sided[from];
    final b = sided[to];
    if (a == null || b == null) return null;
    final dx = (b.x - a.x).abs();
    final dy = (b.y - a.y).abs();
    if (dx == 0 && dy == 0) return 0;
    return math.atan2(dx, dy) * 180 / math.pi;
  }

  @override
  FormCheckResult evaluate(FormCheckContext context) {
    final lean = _leanFromVerticalDeg(context);
    if (lean == null) {
      return const FormCheckResult(CheckStatus.uncertain, 'Torso not visible');
    }
    if (lean > maxLeanFromVerticalDeg) {
      return const FormCheckResult(
        CheckStatus.invalid,
        'Keep your torso more upright - avoid folding forward',
      );
    }
    return FormCheckResult.ok;
  }
}

/// Gates calibration on the primary movement angle being at/above (or
/// below) a threshold, so the athlete calibrates from a genuine start
/// position rather than mid-movement (e.g. already squatting, kneeling, or
/// sitting). Distinguishes calibration from tracking the same way
/// [BodyRigidityCheck] and [LegExtensionCheck] do: [FormCheckContext.reference]
/// is null only during calibration. Once calibrated, this check imposes no
/// constraint at all - the whole point of the primary angle is to move
/// through this threshold during the rep, so restricting it post-calibration
/// would break the exercise it gates.
class CalibrationAngleGateCheck extends FormCheck {
  const CalibrationAngleGateCheck({
    required this.landmarks,
    required this.failureReason,
    this.minDeg,
    this.maxDeg,
  });

  final (BodyPoint, BodyPoint, BodyPoint) landmarks;
  final double? minDeg;
  final double? maxDeg;
  final String failureReason;

  @override
  String get name => 'calibration_angle_gate';

  double? _angle(FormCheckContext context) {
    final sided = context.sidedPose;
    if (sided == null) return null;
    final (a, b, c) = landmarks;
    final pa = sided[a];
    final pb = sided[b];
    final pc = sided[c];
    if (pa == null || pb == null || pc == null) return null;
    return angleBetweenPoints(pa, pb, pc);
  }

  @override
  FormCheckResult evaluate(FormCheckContext context) {
    // Only gates calibration - once a reference exists, tracking has begun
    // and this angle is free to move through its full range.
    if (context.reference != null) return FormCheckResult.ok;

    final angle = _angle(context);
    if (angle == null) {
      return const FormCheckResult(CheckStatus.uncertain, 'Move into frame');
    }
    if ((minDeg != null && angle < minDeg!) || (maxDeg != null && angle > maxDeg!)) {
      return FormCheckResult(CheckStatus.invalid, failureReason);
    }
    return FormCheckResult.ok;
  }
}

/// Limb-extension check: "must stay extended" for any three-landmark joint
/// (hip-knee-ankle for a leg, shoulder-elbow-wrist for an arm), same
/// absolute-floor + reference-tolerance pattern as [BodyRigidityCheck].
/// Originally written for the knee (catches an athlete dropping to their
/// knees and leaning forward, which the other checks don't rule out on
/// their own - that pose can still read as side-on, horizontal, and have a
/// straight shoulder-hip-ankle line), and later reused unchanged for the
/// arm (a plank's straight-arm support requirement is the identical
/// geometric question). [key]/[checkName]/[notVisibleReason]/
/// [invalidReason] are configurable so two independent instances - one for
/// legs, one for arms - can coexist in the same exercise's formChecks list
/// without colliding on the same calibrated reference value; every default
/// matches this class's original knee-only behavior exactly.
class LegExtensionCheck extends FormCheck {
  const LegExtensionCheck({
    this.a = BodyPoint.hip,
    this.b = BodyPoint.knee,
    this.c = BodyPoint.ankle,
    this.absoluteMinDeg = 150,
    this.toleranceDeg = 20,
    this.key = 'legExtensionAngleDeg',
    this.checkName = 'leg_extension',
    this.notVisibleReason = 'Legs not visible',
    this.invalidReason = 'Keep your legs straight - do not drop to your knees',
  });

  final BodyPoint a;
  final BodyPoint b;
  final BodyPoint c;
  final double absoluteMinDeg;
  final double toleranceDeg;
  final String key;
  final String checkName;
  final String notVisibleReason;
  final String invalidReason;

  @override
  String get name => checkName;

  @override
  String? get referenceKey => key;

  double? _angle(FormCheckContext context) {
    final sided = context.sidedPose;
    if (sided == null) return null;
    final pa = sided[a];
    final pb = sided[b];
    final pc = sided[c];
    if (pa == null || pb == null || pc == null) return null;
    return angleBetweenPoints(pa, pb, pc);
  }

  @override
  double? sampleValue(FormCheckContext context) => _angle(context);

  @override
  FormCheckResult evaluate(FormCheckContext context) {
    final angle = _angle(context);
    if (angle == null) {
      return FormCheckResult(CheckStatus.uncertain, notVisibleReason);
    }

    final reference = context.reference?.get(referenceKey!);
    final broken = reference != null
        ? (angle - reference).abs() > toleranceDeg
        : angle < absoluteMinDeg;

    if (broken) {
      return FormCheckResult(CheckStatus.invalid, invalidReason);
    }
    return FormCheckResult.ok;
  }
}

/// Captures an athlete-specific bilateral vertical-position baseline (e.g.
/// standing hip or shoulder height, in image-space Y) during calibration.
/// Imposes no pass/fail constraint beyond landmark visibility - gating on a
/// genuine standing posture is already handled by the other checks in the
/// same config. Exists so an event-triggered [BottomEventValidator] has a
/// global vertical reference to compare against, distinct from any single
/// joint angle.
class VerticalBaselineReferenceCheck extends FormCheck {
  const VerticalBaselineReferenceCheck({
    required this.key,
    required this.sampler,
    this.checkName = 'vertical_baseline_reference',
  });

  final String key;
  final double? Function(Pose pose) sampler;
  final String checkName;

  @override
  String get name => checkName;

  @override
  String? get referenceKey => key;

  @override
  double? sampleValue(FormCheckContext context) => sampler(context.pose);

  @override
  FormCheckResult evaluate(FormCheckContext context) {
    if (sampler(context.pose) == null) {
      return const FormCheckResult(CheckStatus.uncertain, 'Move into frame');
    }
    return FormCheckResult.ok;
  }
}

/// Captures an athlete-specific baseline for a joint angle during
/// calibration, purely as a reference value - imposes no pass/fail
/// constraint beyond landmark visibility, same as
/// [VerticalBaselineReferenceCheck]. Exists for exercises (e.g. Controlled
/// Crunch) whose rep-cycle thresholds are defined as a relative change from
/// the athlete's own calibrated starting angle rather than a fixed
/// universal constant - see [ExerciseConfig.targetRomDeg].
class AngleBaselineReferenceCheck extends FormCheck {
  const AngleBaselineReferenceCheck({
    required this.landmarks,
    required this.key,
    this.checkName = 'angle_baseline_reference',
  });

  final (BodyPoint, BodyPoint, BodyPoint) landmarks;
  final String key;
  final String checkName;

  @override
  String get name => checkName;

  @override
  String? get referenceKey => key;

  double? _angle(FormCheckContext context) {
    final sided = context.sidedPose;
    if (sided == null) return null;
    final (a, b, c) = landmarks;
    final pa = sided[a];
    final pb = sided[b];
    final pc = sided[c];
    if (pa == null || pb == null || pc == null) return null;
    return angleBetweenPoints(pa, pb, pc);
  }

  @override
  double? sampleValue(FormCheckContext context) => _angle(context);

  @override
  FormCheckResult evaluate(FormCheckContext context) {
    if (_angle(context) == null) {
      return const FormCheckResult(CheckStatus.uncertain, 'Move into frame');
    }
    return FormCheckResult.ok;
  }
}

/// Captures an athlete-specific body-scale reference (pixel distance
/// between two landmarks, e.g. hip-to-ankle) during calibration, used to
/// normalize event-triggered displacement measurements for athlete size and
/// camera distance instead of relying on fixed pixel/cm thresholds.
class ScaleReferenceCheck extends FormCheck {
  const ScaleReferenceCheck({required this.a, required this.b, this.key = 'scaleReferencePx'});

  final BodyPoint a;
  final BodyPoint b;
  final String key;

  @override
  String get name => 'scale_reference';

  @override
  String? get referenceKey => key;

  double? _distance(FormCheckContext context) {
    final sided = context.sidedPose;
    if (sided == null) return null;
    final pa = sided[a];
    final pb = sided[b];
    if (pa == null || pb == null) return null;
    return pixelDistance(pa, pb);
  }

  @override
  double? sampleValue(FormCheckContext context) => _distance(context);

  @override
  FormCheckResult evaluate(FormCheckContext context) {
    if (_distance(context) == null) {
      return const FormCheckResult(CheckStatus.uncertain, 'Move into frame');
    }
    return FormCheckResult.ok;
  }
}

/// Small temporal sample of raw (unsmoothed) global-position readings taken
/// around an `AngleCycleEngine`-detected BOTTOM event, plus the athlete's
/// calibrated reference. Distinct from [FormCheckContext]: a
/// [BottomEventValidator] fires once per rep attempt, at the moment a
/// genuine bottom is reached, rather than every frame.
class BottomEventContext {
  const BottomEventContext({
    required this.reference,
    required this.hipYSamples,
    required this.shoulderYSamples,
  });

  final ExerciseReference reference;

  /// Raw hip-midpoint Y readings from the last few frames leading up to the
  /// BOTTOM event, used to smooth out single-frame ML Kit jitter.
  final List<double> hipYSamples;

  /// Raw shoulder-midpoint Y readings over the same trailing window.
  final List<double> shoulderYSamples;
}

/// Outcome of an event-triggered [BottomEventValidator] verdict. Distinct
/// from [CheckStatus]: a bottom event's local knee-angle ROM already looked
/// like a real rep, so a validator here must further distinguish *why* the
/// whole-body movement didn't hold up, since only some of those reasons are
/// genuine form violations.
enum BottomEventOutcome {
  /// Whole-body displacement never cleared the qualifying floor - this
  /// wasn't a squat attempt at all (e.g. a local knee/ankle manipulation
  /// while standing still). No rep, no warning.
  noQualifyingAttempt,

  /// Genuine whole-body movement occurred but didn't reach the required
  /// depth. No rep, no warning - just try again.
  insufficientDepth,

  /// A qualifying, sufficiently deep attempt broke a real form constraint.
  /// Feeds the existing warning/termination lifecycle.
  formViolation,

  /// Not enough reliable data to judge the event either way.
  uncertain,

  /// A genuine, sufficiently deep, form-valid rep.
  valid,
}

class BottomEventResult {
  const BottomEventResult(this.outcome, this.reason);

  static const ok = BottomEventResult(BottomEventOutcome.valid, '');

  final BottomEventOutcome outcome;
  final String reason;
}

/// Validates that an `AngleCycleEngine`-detected BOTTOM event represents
/// genuine whole-body movement rather than a local joint-angle
/// manipulation. Complements the continuous [FormCheck]s, which never see
/// this event in isolation - see [ExerciseConfig.bottomEventValidator].
abstract class BottomEventValidator {
  const BottomEventValidator();

  BottomEventResult validate(BottomEventContext context);
}

/// Classifies a BOTTOM event by how much genuine downward hip travel backed
/// it, and - only once that travel is deep enough to count as a real
/// attempt - whether the apparent descent was primarily an upper-body fold
/// rather than genuine hip/knee movement.
class HipDisplacementValidator extends BottomEventValidator {
  const HipDisplacementValidator({
    this.hipBaselineKey = 'hipBaselineY',
    this.shoulderBaselineKey = 'shoulderBaselineY',
    this.scaleReferenceKey = 'scaleReferencePx',
    this.minQualifyingNormalizedHipDisplacement = 0.18,
    this.minNormalizedHipDisplacement = 0.30,
    this.maxShoulderToHipDisplacementRatio = 2.5,
  });

  final String hipBaselineKey;
  final String shoulderBaselineKey;
  final String scaleReferenceKey;

  /// Small displacement floor, normalized by the athlete's calibrated
  /// hip-to-ankle segment length, whose only job is to tell whether *any*
  /// genuine whole-body squat-like movement happened at all - as opposed to
  /// a local knee/ankle manipulation while otherwise standing still (e.g.
  /// raising one foot). Chosen from the middle of the requested 15-20%
  /// range. Deliberately much smaller than
  /// [minNormalizedHipDisplacement], which judges actual squat depth.
  final double minQualifyingNormalizedHipDisplacement;

  /// Minimum downward hip-midpoint displacement at BOTTOM, normalized by
  /// the athlete's calibrated hip-to-ankle segment length, required for the
  /// attempt to count as reaching full squat depth.
  final double minNormalizedHipDisplacement;

  /// How many times larger the shoulder's vertical displacement is allowed
  /// to be relative to the hip's before the movement is judged to be
  /// primarily an upper-body fold. Natural forward torso lean legitimately
  /// makes the shoulder travel further than the hip during a squat, so
  /// this is a generous multiple, not a 1:1 ratio.
  final double maxShoulderToHipDisplacementRatio;

  double _average(List<double> samples) => samples.reduce((a, b) => a + b) / samples.length;

  @override
  BottomEventResult validate(BottomEventContext context) {
    final hipBaseline = context.reference.get(hipBaselineKey);
    final shoulderBaseline = context.reference.get(shoulderBaselineKey);
    final scaleReference = context.reference.get(scaleReferenceKey);

    if (hipBaseline == null ||
        shoulderBaseline == null ||
        scaleReference == null ||
        scaleReference <= 0 ||
        context.hipYSamples.isEmpty ||
        context.shoulderYSamples.isEmpty) {
      return const BottomEventResult(
        BottomEventOutcome.uncertain,
        'Movement reference unavailable',
      );
    }

    final bottomHipY = _average(context.hipYSamples);
    final bottomShoulderY = _average(context.shoulderYSamples);

    // Image Y grows downward, so a genuine descent shows up as a positive
    // difference here.
    final hipDisplacement = bottomHipY - hipBaseline;
    final shoulderDisplacement = bottomShoulderY - shoulderBaseline;

    final normalizedHipDisplacement = hipDisplacement / scaleReference;

    if (normalizedHipDisplacement < minQualifyingNormalizedHipDisplacement) {
      // No meaningful whole-body movement at all - not a form violation,
      // just not a squat attempt.
      return const BottomEventResult(
        BottomEventOutcome.noQualifyingAttempt,
        'No qualifying squat movement detected',
      );
    }

    if (normalizedHipDisplacement < minNormalizedHipDisplacement) {
      // Real movement, but not deep enough yet - also not a form violation.
      return const BottomEventResult(
        BottomEventOutcome.insufficientDepth,
        'Squat depth not reached - lower your hips further',
      );
    }

    if (shoulderDisplacement > hipDisplacement * maxShoulderToHipDisplacementRatio) {
      return const BottomEventResult(
        BottomEventOutcome.formViolation,
        'Bend at the hips and knees - do not just fold your upper body forward',
      );
    }

    return BottomEventResult.ok;
  }
}
