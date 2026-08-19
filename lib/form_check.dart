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
/// reference-relative) - a Push-up should stay roughly horizontal
/// throughout the whole rep, not just at calibration.
class BodyInclinationCheck extends FormCheck {
  const BodyInclinationCheck({
    this.from = BodyPoint.shoulder,
    this.to = BodyPoint.ankle,
    this.maxInclinationFromHorizontalDeg = 40,
  });

  final BodyPoint from;
  final BodyPoint to;
  final double maxInclinationFromHorizontalDeg;

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
      return const FormCheckResult(
        CheckStatus.invalid,
        'Get into a horizontal push-up plank position',
      );
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

/// Knee-extension check (hip-knee-ankle angle). Catches an athlete dropping
/// to their knees and leaning forward, which the other checks don't rule
/// out on their own: that pose can still read as side-on, horizontal, and
/// have a straight shoulder-hip-ankle line. Same absolute-floor +
/// reference-tolerance pattern as [BodyRigidityCheck].
class LegExtensionCheck extends FormCheck {
  const LegExtensionCheck({
    this.a = BodyPoint.hip,
    this.b = BodyPoint.knee,
    this.c = BodyPoint.ankle,
    this.absoluteMinDeg = 150,
    this.toleranceDeg = 20,
  });

  final BodyPoint a;
  final BodyPoint b;
  final BodyPoint c;
  final double absoluteMinDeg;
  final double toleranceDeg;

  @override
  String get name => 'leg_extension';

  @override
  String? get referenceKey => 'legExtensionAngleDeg';

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
      return const FormCheckResult(CheckStatus.uncertain, 'Legs not visible');
    }

    final reference = context.reference?.get(referenceKey!);
    final broken = reference != null
        ? (angle - reference).abs() > toleranceDeg
        : angle < absoluteMinDeg;

    if (broken) {
      return const FormCheckResult(
        CheckStatus.invalid,
        'Keep your legs straight - do not drop to your knees',
      );
    }
    return FormCheckResult.ok;
  }
}
