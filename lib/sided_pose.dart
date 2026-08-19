import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import 'pose_utils.dart';

/// Named body landmarks relevant to a side-view exercise. Exercise configs
/// reference these instead of raw left/right [PoseLandmarkType] values, so
/// the same geometry code works regardless of which side of the body faces
/// the camera.
enum BodyPoint { shoulder, elbow, wrist, hip, knee, ankle }

const Map<BodyPoint, (PoseLandmarkType, PoseLandmarkType)> _kBodyPointTypes = {
  BodyPoint.shoulder: (PoseLandmarkType.leftShoulder, PoseLandmarkType.rightShoulder),
  BodyPoint.elbow: (PoseLandmarkType.leftElbow, PoseLandmarkType.rightElbow),
  BodyPoint.wrist: (PoseLandmarkType.leftWrist, PoseLandmarkType.rightWrist),
  BodyPoint.hip: (PoseLandmarkType.leftHip, PoseLandmarkType.rightHip),
  BodyPoint.knee: (PoseLandmarkType.leftKnee, PoseLandmarkType.rightKnee),
  BodyPoint.ankle: (PoseLandmarkType.leftAnkle, PoseLandmarkType.rightAnkle),
};

/// The subset of [BodyPoint]s confidently visible on one side of the body
/// this frame.
class SidedPose {
  const SidedPose({required this.points, required this.isLeftSide});

  final Map<BodyPoint, PoseLandmark> points;
  final bool isLeftSide;

  PoseLandmark? operator [](BodyPoint point) => points[point];
}

/// Resolves which side (left/right) of the body faces the camera and
/// extracts [requiredPoints] for that side, or null if neither side has all
/// of them confidently visible.
///
/// If [preferLeftSide] is given and that side is still confidently
/// extractable this frame, it's kept even if the other side's confidence
/// momentarily edges ahead - avoids two genuinely different landmark sets
/// flip-flopping frame to frame.
SidedPose? resolveSidedPose(
  Pose pose, {
  required List<BodyPoint> requiredPoints,
  required double confidenceThreshold,
  bool? preferLeftSide,
}) {
  SidedPose? tryExtract(bool left) {
    final points = <BodyPoint, PoseLandmark>{};
    for (final point in requiredPoints) {
      final types = _kBodyPointTypes[point]!;
      final landmark = pose.landmarks[left ? types.$1 : types.$2];
      if (!isLandmarkVisible(landmark, threshold: confidenceThreshold)) return null;
      points[point] = landmark!;
    }
    return SidedPose(points: points, isLeftSide: left);
  }

  if (preferLeftSide != null) {
    final preferred = tryExtract(preferLeftSide);
    if (preferred != null) return preferred;
  }

  final left = tryExtract(true);
  final right = tryExtract(false);
  if (left != null && right == null) return left;
  if (right != null && left == null) return right;
  if (left != null && right != null) {
    final leftShoulder = left[BodyPoint.shoulder]?.likelihood ?? 0;
    final leftHip = left[BodyPoint.hip]?.likelihood ?? 0;
    final rightShoulder = right[BodyPoint.shoulder]?.likelihood ?? 0;
    final rightHip = right[BodyPoint.hip]?.likelihood ?? 0;
    return (leftShoulder + leftHip) >= (rightShoulder + rightHip) ? left : right;
  }
  return null;
}
