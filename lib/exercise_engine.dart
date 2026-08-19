import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

enum ExerciseType { verticalJump, pushUp, squat }

class ExerciseStatus {
  const ExerciseStatus({
    required this.primaryText,
    this.secondaryText,
    required this.isBodyVisible,
  });

  final String primaryText;
  final String? secondaryText;
  final bool isBodyVisible;
}

abstract class ExerciseEngine {
  ExerciseStatus get status;

  void reset();

  void processPose(Pose? pose);

  /// Raw image-space Y of an adaptive on-screen reference guide, or null if
  /// the engine doesn't use one. Engines that don't need one inherit this
  /// harmless default.
  double? get groundGuideImageY => null;
}
