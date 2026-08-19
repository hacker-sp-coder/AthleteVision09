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

  /// Whether the UI should show a static "stand here" position guide over
  /// the camera preview right now. Engines that don't need one inherit this
  /// harmless default.
  bool get showPositionGuide => false;

  /// TEMPORARY: multi-line diagnostic text to surface on screen, or null if
  /// the engine has none to show. Engines that don't need this inherit the
  /// harmless default. Remove once no longer needed for physical-test
  /// debugging.
  String? get diagnosticText => null;
}
