import 'dart:math' as math;

import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import 'pose_utils.dart';

// --- Calibration: fixed absolute thresholds (a static hold already
// suppresses noise, so these don't need per-athlete tolerance bands). ---
const double kMaxSideOnShoulderRatio = 0.55;
const double kMinPositionLikelihood = 0.3;
const double kMaxBodyInclinationDeg = 40;
const double kMaxGroundReferenceAngleDeg = 45;
const double kMinBodyLineStraightness = 155;
const double kMinShoulderHipKneeStraightness = 155;
const double kMinLegStraightness = 160;
const double kMaxShoulderWristOffsetRatio = 0.7;
const double kMinTopElbowAngle = 155;

// --- Continuous validation: tolerance bands around the athlete's own
// calibrated reference, not global constants - this is what makes it an
// athlete-specific envelope rather than a second copy of the calibration
// gate. Elbow angle and vertical position are deliberately excluded: those
// are the dimensions expected to change during a real rep. ---
const double kSideOnRatioTolerance = 0.15;
const double kBodyInclinationToleranceDeg = 15;
const double kGroundReferenceToleranceDeg = 20;
const double kBodyLineToleranceDeg = 18;
const double kShoulderHipKneeToleranceDeg = 18;
const double kLegStraightnessToleranceDeg = 18;
const double kShoulderWristTolerance = 0.25;
const double kElbowAngleSanityMin = 50;
const double kMinBodySpanScaleRatio = 0.7;
const double kMaxBodySpanScaleRatio = 1.4;

enum FormStatus { valid, invalid, uncertain }

enum FormViolation {
  none,
  landmarksMissing,
  notSideOn,
  tooUpright,
  groundReferenceInvalid,
  bodyLineBroken,
  hipsBroken,
  legsBent,
  armsNotExtended,
  supportShifted,
  elbowImplausible,
  scaleDrift,
}

class FormValidationResult {
  const FormValidationResult({
    required this.status,
    required this.violation,
    required this.reason,
    required this.confidence,
  });

  final FormStatus status;
  final FormViolation violation;
  final String reason;
  final double confidence;

  bool get isValid => status == FormStatus.valid;
}

/// One side (left or right) of the body's push-up-relevant landmarks -
/// whichever side faces the camera in a side-on view.
class _SidePose {
  const _SidePose({
    required this.shoulder,
    required this.elbow,
    required this.wrist,
    required this.hip,
    required this.knee,
    required this.ankle,
    required this.otherShoulder,
  });

  final PoseLandmark shoulder;
  final PoseLandmark elbow;
  final PoseLandmark wrist;
  final PoseLandmark hip;
  final PoseLandmark knee;
  final PoseLandmark ankle;

  /// Opposite shoulder, used only to judge side-on-ness. Nullable since it's
  /// commonly (and correctly, in good side-on form) partially occluded.
  final PoseLandmark? otherShoulder;
}

/// A single frame's worth of push-up-relevant geometry, normalized to angles
/// and body-scale ratios rather than raw pixel positions wherever possible.
class PushUpPoseMetrics {
  const PushUpPoseMetrics({
    required this.torsoLengthPx,
    required this.bodySpanPx,
    required this.elbowAngleDeg,
    required this.bodyLineAngleDeg,
    required this.shoulderHipKneeAngleDeg,
    required this.hipKneeAnkleAngleDeg,
    required this.bodyInclinationDeg,
    required this.groundReferenceAngleDeg,
    required this.groundGuideImageY,
    required this.shoulderWristOffsetRatio,
    required this.sideOnRatio,
    required this.landmarkConfidence,
    required this.isLeftSide,
  });

  /// Shoulder-hip pixel distance - used only as the denominator for
  /// [sideOnRatio].
  final double torsoLengthPx;

  /// Shoulder-ankle pixel distance - a longer, straighter, lower-relative-
  /// noise body-scale reference used for camera-distance drift detection.
  final double bodySpanPx;

  final double elbowAngleDeg;

  /// Shoulder-hip-ankle angle, degrees; 180 = perfectly straight.
  final double bodyLineAngleDeg;

  /// Shoulder-hip-knee angle, degrees; catches hip pike/sag independently
  /// of ankle noise.
  final double shoulderHipKneeAngleDeg;

  /// Hip-knee-ankle angle, degrees; leg straightness.
  final double hipKneeAnkleAngleDeg;

  /// Angle of the shoulder->hip vector from horizontal, in [0,90].
  /// 0 = horizontal plank, 90 = vertical/standing.
  final double bodyInclinationDeg;

  /// Angle of the wrist->ankle vector from horizontal, in [0,90]. In a
  /// genuine push-up TOP both hand and foot are ground-contact points, so
  /// this line approximates the floor - a ground-contact plausibility check
  /// and the source for the on-screen ground guide, not an independent
  /// second orientation signal (it's correlated with [bodyInclinationDeg]
  /// in the common standing-vs-plank case).
  final double groundReferenceAngleDeg;

  /// Midpoint of wrist.y/ankle.y, raw image coordinates, for the overlay
  /// ground guide line.
  final double groundGuideImageY;

  /// Horizontal shoulder-wrist offset normalized by torso length - the
  /// "hands in a plausible support position" signal.
  final double shoulderWristOffsetRatio;

  /// Shoulder width / torso length. Null means inconclusive (far shoulder
  /// not confidently visible), not "not side-on".
  final double? sideOnRatio;

  /// Min likelihood among the 6 required landmarks.
  final double landmarkConfidence;

  final bool isLeftSide;

  /// EMA-blends every numeric field against [previous]. Leaves [sideOnRatio]
  /// as this frame's raw value and [isLeftSide] as this frame's raw
  /// selection - both need special handling by the caller (see
  /// [withSideOnRatio] and side-selection stickiness in PushUpEngine).
  PushUpPoseMetrics smoothedTowards(PushUpPoseMetrics? previous, double alpha) {
    if (previous == null) return this;
    double blend(double a, double b) => alpha * a + (1 - alpha) * b;
    return PushUpPoseMetrics(
      torsoLengthPx: blend(torsoLengthPx, previous.torsoLengthPx),
      bodySpanPx: blend(bodySpanPx, previous.bodySpanPx),
      elbowAngleDeg: blend(elbowAngleDeg, previous.elbowAngleDeg),
      bodyLineAngleDeg: blend(bodyLineAngleDeg, previous.bodyLineAngleDeg),
      shoulderHipKneeAngleDeg:
          blend(shoulderHipKneeAngleDeg, previous.shoulderHipKneeAngleDeg),
      hipKneeAnkleAngleDeg: blend(hipKneeAnkleAngleDeg, previous.hipKneeAnkleAngleDeg),
      bodyInclinationDeg: blend(bodyInclinationDeg, previous.bodyInclinationDeg),
      groundReferenceAngleDeg:
          blend(groundReferenceAngleDeg, previous.groundReferenceAngleDeg),
      groundGuideImageY: blend(groundGuideImageY, previous.groundGuideImageY),
      shoulderWristOffsetRatio:
          blend(shoulderWristOffsetRatio, previous.shoulderWristOffsetRatio),
      sideOnRatio: sideOnRatio,
      landmarkConfidence: blend(landmarkConfidence, previous.landmarkConfidence),
      isLeftSide: isLeftSide,
    );
  }

  PushUpPoseMetrics withSideOnRatio(double? value) {
    return PushUpPoseMetrics(
      torsoLengthPx: torsoLengthPx,
      bodySpanPx: bodySpanPx,
      elbowAngleDeg: elbowAngleDeg,
      bodyLineAngleDeg: bodyLineAngleDeg,
      shoulderHipKneeAngleDeg: shoulderHipKneeAngleDeg,
      hipKneeAnkleAngleDeg: hipKneeAnkleAngleDeg,
      bodyInclinationDeg: bodyInclinationDeg,
      groundReferenceAngleDeg: groundReferenceAngleDeg,
      groundGuideImageY: groundGuideImageY,
      shoulderWristOffsetRatio: shoulderWristOffsetRatio,
      sideOnRatio: value,
      landmarkConfidence: landmarkConfidence,
      isLeftSide: isLeftSide,
    );
  }
}

/// An athlete-specific, normalized valid-form envelope captured from the
/// calibration stability window. Angles/ratios/scale only - never raw
/// coordinates.
class PushUpReferenceModel {
  const PushUpReferenceModel({
    required this.torsoLengthPx,
    required this.bodySpanPx,
    required this.elbowAngleDeg,
    required this.bodyLineAngleDeg,
    required this.shoulderHipKneeAngleDeg,
    required this.hipKneeAnkleAngleDeg,
    required this.bodyInclinationDeg,
    required this.groundReferenceAngleDeg,
    required this.shoulderWristOffsetRatio,
    required this.sideOnRatio,
  });

  final double torsoLengthPx;
  final double bodySpanPx;
  final double elbowAngleDeg;
  final double bodyLineAngleDeg;
  final double shoulderHipKneeAngleDeg;
  final double hipKneeAnkleAngleDeg;
  final double bodyInclinationDeg;
  final double groundReferenceAngleDeg;
  final double shoulderWristOffsetRatio;
  final double sideOnRatio;
}

class PushUpFormValidator {
  const PushUpFormValidator._();

  static bool _visible(PoseLandmark? landmark, {double threshold = kMinLandmarkLikelihood}) =>
      isLandmarkVisible(landmark, threshold: threshold);

  static _SidePose? _extractSide(Pose pose, bool left) {
    final shoulder = pose.landmarks[
        left ? PoseLandmarkType.leftShoulder : PoseLandmarkType.rightShoulder];
    final elbow = pose
        .landmarks[left ? PoseLandmarkType.leftElbow : PoseLandmarkType.rightElbow];
    final wrist = pose
        .landmarks[left ? PoseLandmarkType.leftWrist : PoseLandmarkType.rightWrist];
    final hip =
        pose.landmarks[left ? PoseLandmarkType.leftHip : PoseLandmarkType.rightHip];
    final knee =
        pose.landmarks[left ? PoseLandmarkType.leftKnee : PoseLandmarkType.rightKnee];
    final ankle = pose
        .landmarks[left ? PoseLandmarkType.leftAnkle : PoseLandmarkType.rightAnkle];
    final otherShoulder = pose.landmarks[
        left ? PoseLandmarkType.rightShoulder : PoseLandmarkType.leftShoulder];

    if (!_visible(shoulder) ||
        !_visible(elbow) ||
        !_visible(wrist) ||
        !_visible(hip) ||
        !_visible(knee) ||
        !_visible(ankle)) {
      return null;
    }

    return _SidePose(
      shoulder: shoulder!,
      elbow: elbow!,
      wrist: wrist!,
      hip: hip!,
      knee: knee!,
      ankle: ankle!,
      otherShoulder: otherShoulder,
    );
  }

  /// Picks the near-camera side. If [preferLeftSide] is still confidently
  /// extractable this frame, keeps using it even if the other side's score
  /// momentarily edges ahead - avoids two genuinely different landmark sets
  /// flip-flopping frame to frame.
  static (_SidePose, bool)? _resolveSide(Pose pose, {bool? preferLeftSide}) {
    if (preferLeftSide != null) {
      final preferred = _extractSide(pose, preferLeftSide);
      if (preferred != null) return (preferred, preferLeftSide);
    }

    final left = _extractSide(pose, true);
    final right = _extractSide(pose, false);
    if (left != null && right == null) return (left, true);
    if (right != null && left == null) return (right, false);
    if (left != null && right != null) {
      final leftScore = left.shoulder.likelihood + left.hip.likelihood;
      final rightScore = right.shoulder.likelihood + right.hip.likelihood;
      return leftScore >= rightScore ? (left, true) : (right, false);
    }
    return null;
  }

  static double _lineInclinationDeg(PoseLandmark a, PoseLandmark b) {
    final dx = (b.x - a.x).abs();
    final dy = (b.y - a.y).abs();
    if (dx == 0 && dy == 0) return 90;
    return math.atan2(dy, dx) * 180 / math.pi;
  }

  /// Cheap preliminary side-on-ness check needing only both shoulders and
  /// whichever hip is visible - used to distinguish the earliest calibration
  /// stages before the full 6-landmark set is necessarily available yet.
  static double? lightSideOnCheck(Pose pose) {
    final leftShoulder = pose.landmarks[PoseLandmarkType.leftShoulder];
    final rightShoulder = pose.landmarks[PoseLandmarkType.rightShoulder];
    if (!_visible(leftShoulder) || !_visible(rightShoulder)) return null;

    final leftHip = pose.landmarks[PoseLandmarkType.leftHip];
    final rightHip = pose.landmarks[PoseLandmarkType.rightHip];
    PoseLandmark? hip;
    if (_visible(leftHip) && _visible(rightHip)) {
      hip = leftHip!.likelihood >= rightHip!.likelihood ? leftHip : rightHip;
    } else if (_visible(leftHip)) {
      hip = leftHip;
    } else if (_visible(rightHip)) {
      hip = rightHip;
    }
    if (hip == null) return null;

    final midShoulderX = (leftShoulder!.x + rightShoulder!.x) / 2;
    final midShoulderY = (leftShoulder.y + rightShoulder.y) / 2;
    final dx = midShoulderX - hip.x;
    final dy = midShoulderY - hip.y;
    final torsoLength = math.sqrt(dx * dx + dy * dy);
    if (torsoLength <= 0) return null;

    final shoulderWidth = pixelDistance(leftShoulder, rightShoulder);
    return shoulderWidth / torsoLength;
  }

  static PushUpPoseMetrics? computeMetrics(Pose pose, {bool? preferLeftSide}) {
    final resolved = _resolveSide(pose, preferLeftSide: preferLeftSide);
    if (resolved == null) return null;
    final (side, isLeft) = resolved;

    final torsoLengthPx = pixelDistance(side.shoulder, side.hip);
    if (torsoLengthPx <= 0) return null;

    final bodySpanPx = pixelDistance(side.shoulder, side.ankle);
    final elbowAngleDeg = angleBetweenPoints(side.shoulder, side.elbow, side.wrist);
    final bodyLineAngleDeg = angleBetweenPoints(side.shoulder, side.hip, side.ankle);
    final shoulderHipKneeAngleDeg =
        angleBetweenPoints(side.shoulder, side.hip, side.knee);
    final hipKneeAnkleAngleDeg = angleBetweenPoints(side.hip, side.knee, side.ankle);
    final bodyInclinationDeg = _lineInclinationDeg(side.shoulder, side.hip);
    final groundReferenceAngleDeg = _lineInclinationDeg(side.wrist, side.ankle);
    final groundGuideImageY = (side.wrist.y + side.ankle.y) / 2;
    final shoulderWristOffsetRatio =
        (side.wrist.x - side.shoulder.x).abs() / torsoLengthPx;

    double? sideOnRatio;
    final other = side.otherShoulder;
    if (other != null && other.likelihood >= kMinPositionLikelihood) {
      sideOnRatio = pixelDistance(side.shoulder, other) / torsoLengthPx;
    }

    final landmarkConfidence = [
      side.shoulder.likelihood,
      side.elbow.likelihood,
      side.wrist.likelihood,
      side.hip.likelihood,
      side.knee.likelihood,
      side.ankle.likelihood,
    ].reduce(math.min);

    return PushUpPoseMetrics(
      torsoLengthPx: torsoLengthPx,
      bodySpanPx: bodySpanPx,
      elbowAngleDeg: elbowAngleDeg,
      bodyLineAngleDeg: bodyLineAngleDeg,
      shoulderHipKneeAngleDeg: shoulderHipKneeAngleDeg,
      hipKneeAnkleAngleDeg: hipKneeAnkleAngleDeg,
      bodyInclinationDeg: bodyInclinationDeg,
      groundReferenceAngleDeg: groundReferenceAngleDeg,
      groundGuideImageY: groundGuideImageY,
      shoulderWristOffsetRatio: shoulderWristOffsetRatio,
      sideOnRatio: sideOnRatio,
      landmarkConfidence: landmarkConfidence,
      isLeftSide: isLeft,
    );
  }

  static FormValidationResult? _uncertainIfSideOnUnknown(PushUpPoseMetrics metrics) {
    if (metrics.sideOnRatio == null) {
      return FormValidationResult(
        status: FormStatus.uncertain,
        violation: FormViolation.notSideOn,
        reason: 'Turn sideways so one shoulder is hidden behind the other',
        confidence: metrics.landmarkConfidence,
      );
    }
    return null;
  }

  /// Fixed absolute thresholds: is this single frame, in isolation, a
  /// plausible push-up TOP? Used only during calibration.
  static FormValidationResult evaluateTopCandidate(PushUpPoseMetrics metrics) {
    final uncertain = _uncertainIfSideOnUnknown(metrics);
    if (uncertain != null) return uncertain;

    if (metrics.sideOnRatio! > kMaxSideOnShoulderRatio) {
      return FormValidationResult(
        status: FormStatus.invalid,
        violation: FormViolation.notSideOn,
        reason: 'Turn more sideways to the camera',
        confidence: metrics.landmarkConfidence,
      );
    }
    if (metrics.bodyInclinationDeg > kMaxBodyInclinationDeg) {
      return FormValidationResult(
        status: FormStatus.invalid,
        violation: FormViolation.tooUpright,
        reason: 'Get into a horizontal push-up plank position',
        confidence: metrics.landmarkConfidence,
      );
    }
    if (metrics.groundReferenceAngleDeg > kMaxGroundReferenceAngleDeg) {
      return FormValidationResult(
        status: FormStatus.invalid,
        violation: FormViolation.groundReferenceInvalid,
        reason: 'Hands and feet should be near the same ground level',
        confidence: metrics.landmarkConfidence,
      );
    }
    if (metrics.bodyLineAngleDeg < kMinBodyLineStraightness) {
      return FormValidationResult(
        status: FormStatus.invalid,
        violation: FormViolation.bodyLineBroken,
        reason: 'Keep your body straight - avoid hip sag or pike',
        confidence: metrics.landmarkConfidence,
      );
    }
    if (metrics.shoulderHipKneeAngleDeg < kMinShoulderHipKneeStraightness) {
      return FormValidationResult(
        status: FormStatus.invalid,
        violation: FormViolation.hipsBroken,
        reason: 'Straighten your hips',
        confidence: metrics.landmarkConfidence,
      );
    }
    if (metrics.hipKneeAnkleAngleDeg < kMinLegStraightness) {
      return FormValidationResult(
        status: FormStatus.invalid,
        violation: FormViolation.legsBent,
        reason: 'Straighten your legs',
        confidence: metrics.landmarkConfidence,
      );
    }
    if (metrics.shoulderWristOffsetRatio > kMaxShoulderWristOffsetRatio) {
      return FormValidationResult(
        status: FormStatus.invalid,
        violation: FormViolation.supportShifted,
        reason: 'Position your hands under your shoulders',
        confidence: metrics.landmarkConfidence,
      );
    }
    if (metrics.elbowAngleDeg < kMinTopElbowAngle) {
      return FormValidationResult(
        status: FormStatus.invalid,
        violation: FormViolation.armsNotExtended,
        reason: 'Extend your arms fully',
        confidence: metrics.landmarkConfidence,
      );
    }

    return FormValidationResult(
      status: FormStatus.valid,
      violation: FormViolation.none,
      reason: 'Valid push-up starting position',
      confidence: metrics.landmarkConfidence,
    );
  }

  /// Reference-relative tolerance bands: has the athlete drifted outside
  /// their own calibrated envelope? Elbow angle (broad sanity floor only)
  /// and vertical position (not checked at all) are deliberately excluded -
  /// those are expected to move during a genuine rep.
  static FormValidationResult evaluateAgainstReference(
    PushUpPoseMetrics metrics,
    PushUpReferenceModel reference,
  ) {
    final uncertain = _uncertainIfSideOnUnknown(metrics);
    if (uncertain != null) return uncertain;

    if ((metrics.sideOnRatio! - reference.sideOnRatio).abs() > kSideOnRatioTolerance) {
      return FormValidationResult(
        status: FormStatus.invalid,
        violation: FormViolation.notSideOn,
        reason: 'Stay side-on to the camera, matching your starting position',
        confidence: metrics.landmarkConfidence,
      );
    }
    if ((metrics.bodyInclinationDeg - reference.bodyInclinationDeg).abs() >
        kBodyInclinationToleranceDeg) {
      return FormValidationResult(
        status: FormStatus.invalid,
        violation: FormViolation.tooUpright,
        reason: 'Keep your body at the same angle as your starting position',
        confidence: metrics.landmarkConfidence,
      );
    }
    if ((metrics.groundReferenceAngleDeg - reference.groundReferenceAngleDeg).abs() >
        kGroundReferenceToleranceDeg) {
      return FormValidationResult(
        status: FormStatus.invalid,
        violation: FormViolation.groundReferenceInvalid,
        reason: 'Keep your hand and foot support consistent',
        confidence: metrics.landmarkConfidence,
      );
    }
    if ((metrics.bodyLineAngleDeg - reference.bodyLineAngleDeg).abs() >
        kBodyLineToleranceDeg) {
      return FormValidationResult(
        status: FormStatus.invalid,
        violation: FormViolation.bodyLineBroken,
        reason: 'Keep your body straight - avoid hip sag or pike',
        confidence: metrics.landmarkConfidence,
      );
    }
    if ((metrics.shoulderHipKneeAngleDeg - reference.shoulderHipKneeAngleDeg).abs() >
        kShoulderHipKneeToleranceDeg) {
      return FormValidationResult(
        status: FormStatus.invalid,
        violation: FormViolation.hipsBroken,
        reason: 'Keep your hips steady',
        confidence: metrics.landmarkConfidence,
      );
    }
    if ((metrics.hipKneeAnkleAngleDeg - reference.hipKneeAnkleAngleDeg).abs() >
        kLegStraightnessToleranceDeg) {
      return FormValidationResult(
        status: FormStatus.invalid,
        violation: FormViolation.legsBent,
        reason: 'Keep your legs straight',
        confidence: metrics.landmarkConfidence,
      );
    }
    if ((metrics.shoulderWristOffsetRatio - reference.shoulderWristOffsetRatio).abs() >
        kShoulderWristTolerance) {
      return FormValidationResult(
        status: FormStatus.invalid,
        violation: FormViolation.supportShifted,
        reason: 'Keep your hand support position steady',
        confidence: metrics.landmarkConfidence,
      );
    }
    if (metrics.elbowAngleDeg < kElbowAngleSanityMin) {
      return FormValidationResult(
        status: FormStatus.invalid,
        violation: FormViolation.elbowImplausible,
        reason: 'Elbow angle looks implausible - reposition',
        confidence: metrics.landmarkConfidence,
      );
    }
    final scaleRatio = metrics.bodySpanPx / reference.bodySpanPx;
    if (scaleRatio < kMinBodySpanScaleRatio || scaleRatio > kMaxBodySpanScaleRatio) {
      return FormValidationResult(
        status: FormStatus.invalid,
        violation: FormViolation.scaleDrift,
        reason: 'Stay at the same distance from the camera',
        confidence: metrics.landmarkConfidence,
      );
    }

    return FormValidationResult(
      status: FormStatus.valid,
      violation: FormViolation.none,
      reason: 'Valid push-up form',
      confidence: metrics.landmarkConfidence,
    );
  }

  /// Averages a set of stability-window samples into an athlete-specific
  /// reference envelope.
  static PushUpReferenceModel buildReferenceModel(List<PushUpPoseMetrics> samples) {
    double avg(double Function(PushUpPoseMetrics) f) =>
        samples.map(f).reduce((a, b) => a + b) / samples.length;

    final sideOnSamples = samples
        .map((m) => m.sideOnRatio)
        .whereType<double>()
        .toList();
    final avgSideOn = sideOnSamples.isEmpty
        ? kMaxSideOnShoulderRatio
        : sideOnSamples.reduce((a, b) => a + b) / sideOnSamples.length;

    return PushUpReferenceModel(
      torsoLengthPx: avg((m) => m.torsoLengthPx),
      bodySpanPx: avg((m) => m.bodySpanPx),
      elbowAngleDeg: avg((m) => m.elbowAngleDeg),
      bodyLineAngleDeg: avg((m) => m.bodyLineAngleDeg),
      shoulderHipKneeAngleDeg: avg((m) => m.shoulderHipKneeAngleDeg),
      hipKneeAnkleAngleDeg: avg((m) => m.hipKneeAnkleAngleDeg),
      bodyInclinationDeg: avg((m) => m.bodyInclinationDeg),
      groundReferenceAngleDeg: avg((m) => m.groundReferenceAngleDeg),
      shoulderWristOffsetRatio: avg((m) => m.shoulderWristOffsetRatio),
      sideOnRatio: avgSideOn,
    );
  }
}
