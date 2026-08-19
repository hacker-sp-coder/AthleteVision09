import 'dart:math' as math;

import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

/// Minimum ML Kit landmark likelihood required to trust a point.
const double kMinLandmarkLikelihood = 0.6;

/// Empirical correction factor applied to the raw nose-to-ankle pixel span
/// to approximate true standing height (top-of-head to floor). The nose sits
/// below the crown and the ankle joint sits above the sole, so the raw span
/// systematically understates real height by roughly 10-12%.
const double kHeightCorrectionFactor = 1.10;

const List<PoseLandmarkType> kFullBodyLandmarks = [
  PoseLandmarkType.nose,
  PoseLandmarkType.leftShoulder,
  PoseLandmarkType.rightShoulder,
  PoseLandmarkType.leftHip,
  PoseLandmarkType.rightHip,
  PoseLandmarkType.leftKnee,
  PoseLandmarkType.rightKnee,
  PoseLandmarkType.leftAnkle,
  PoseLandmarkType.rightAnkle,
];

bool isLandmarkVisible(
  PoseLandmark? landmark, {
  double threshold = kMinLandmarkLikelihood,
}) {
  return landmark != null && landmark.likelihood >= threshold;
}

/// Angle at vertex [b], in degrees, formed by points [a]-[b]-[c]. 2D only.
double angleBetweenPoints(PoseLandmark a, PoseLandmark b, PoseLandmark c) {
  final v1x = a.x - b.x;
  final v1y = a.y - b.y;
  final v2x = c.x - b.x;
  final v2y = c.y - b.y;

  final dot = v1x * v2x + v1y * v2y;
  final mag1 = math.sqrt(v1x * v1x + v1y * v1y);
  final mag2 = math.sqrt(v2x * v2x + v2y * v2y);
  if (mag1 == 0 || mag2 == 0) return 0;

  final cosAngle = (dot / (mag1 * mag2)).clamp(-1.0, 1.0);
  return math.acos(cosAngle) * 180 / math.pi;
}

/// 2D Euclidean pixel distance between two landmarks.
double pixelDistance(PoseLandmark a, PoseLandmark b) {
  final dx = a.x - b.x;
  final dy = a.y - b.y;
  return math.sqrt(dx * dx + dy * dy);
}

double? averageAnkleY(Pose pose, {double threshold = kMinLandmarkLikelihood}) {
  final left = pose.landmarks[PoseLandmarkType.leftAnkle];
  final right = pose.landmarks[PoseLandmarkType.rightAnkle];
  final leftVisible = isLandmarkVisible(left, threshold: threshold);
  final rightVisible = isLandmarkVisible(right, threshold: threshold);

  if (leftVisible && rightVisible) return (left!.y + right!.y) / 2;
  if (leftVisible) return left!.y;
  if (rightVisible) return right!.y;
  return null;
}

double? averageHipY(Pose pose, {double threshold = kMinLandmarkLikelihood}) {
  final left = pose.landmarks[PoseLandmarkType.leftHip];
  final right = pose.landmarks[PoseLandmarkType.rightHip];
  final leftVisible = isLandmarkVisible(left, threshold: threshold);
  final rightVisible = isLandmarkVisible(right, threshold: threshold);

  if (leftVisible && rightVisible) return (left!.y + right!.y) / 2;
  if (leftVisible) return left!.y;
  if (rightVisible) return right!.y;
  return null;
}

double? averageShoulderY(Pose pose, {double threshold = kMinLandmarkLikelihood}) {
  final left = pose.landmarks[PoseLandmarkType.leftShoulder];
  final right = pose.landmarks[PoseLandmarkType.rightShoulder];
  final leftVisible = isLandmarkVisible(left, threshold: threshold);
  final rightVisible = isLandmarkVisible(right, threshold: threshold);

  if (leftVisible && rightVisible) return (left!.y + right!.y) / 2;
  if (leftVisible) return left!.y;
  if (rightVisible) return right!.y;
  return null;
}

/// Checks that all [requiredLandmarks] are present with likelihood >= [threshold].
bool isFullBodyVisible(
  Pose pose, {
  double threshold = kMinLandmarkLikelihood,
  List<PoseLandmarkType> requiredLandmarks = kFullBodyLandmarks,
}) {
  for (final type in requiredLandmarks) {
    if (!isLandmarkVisible(pose.landmarks[type], threshold: threshold)) {
      return false;
    }
  }
  return true;
}

/// Nose-to-average-ankle pixel distance, used as a proxy for standing height
/// in pixels. Requires the nose and at least one ankle to be visible.
double? estimateStandingHeightPixels(
  Pose pose, {
  double threshold = kMinLandmarkLikelihood,
}) {
  final nose = pose.landmarks[PoseLandmarkType.nose];
  if (!isLandmarkVisible(nose, threshold: threshold)) return null;

  final ankleY = averageAnkleY(pose, threshold: threshold);
  if (ankleY == null) return null;

  return (ankleY - nose!.y).abs();
}

/// Centimeters represented by one pixel, derived from a measured pixel
/// height and the user's known real height.
double? cmPerPixel(double heightPixels, double realHeightCm) {
  if (heightPixels <= 0) return null;
  return realHeightCm / (heightPixels * kHeightCorrectionFactor);
}
