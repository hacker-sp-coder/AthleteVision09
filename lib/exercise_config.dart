import 'form_check.dart';
import 'pose_utils.dart';
import 'sided_pose.dart';

/// Exercise-specific configuration consumed by the generic
/// `AngleCycleEngine`. The engine owns the reusable rep-cycle mechanics;
/// this object owns the biomechanics - which landmarks, which thresholds,
/// which form checks - for one particular exercise.
class ExerciseConfig {
  const ExerciseConfig({
    required this.name,
    required this.setupInstruction,
    required this.requiredPoints,
    required this.angleLandmarks,
    required this.topAngleThresholdDeg,
    required this.bottomAngleThresholdDeg,
    required this.formChecks,
    this.landmarkConfidenceThreshold = kMinLandmarkLikelihood,
    this.emaAlpha = 0.4,
    this.stabilityWindow = const Duration(milliseconds: 1500),
    this.minRepInterval = const Duration(milliseconds: 600),
    this.maxUncertainFrames = 5,
  });

  final String name;
  final String setupInstruction;

  /// All landmarks that must be confidently visible on one side for a frame
  /// to be usable at all.
  final List<BodyPoint> requiredPoints;

  /// Triplet driving the primary rep-cycle angle (e.g. shoulder-elbow-wrist
  /// for push-ups).
  final (BodyPoint, BodyPoint, BodyPoint) angleLandmarks;

  /// Angle at/above which the athlete counts as at the TOP of the cycle.
  final double topAngleThresholdDeg;

  /// Angle at/below which the athlete counts as at the BOTTOM of the cycle.
  final double bottomAngleThresholdDeg;

  final List<FormCheck> formChecks;
  final double landmarkConfidenceThreshold;
  final double emaAlpha;
  final Duration stabilityWindow;
  final Duration minRepInterval;

  /// Consecutive UNCERTAIN frames tolerated before escalating to INVALID
  /// and invalidating the current trajectory.
  final int maxUncertainFrames;
}

final ExerciseConfig pushUpExerciseConfig = ExerciseConfig(
  name: 'Push-ups',
  setupInstruction:
      'Turn sideways to the camera, keep your entire body visible, and get '
      'into the starting push-up position.',
  requiredPoints: const [
    BodyPoint.shoulder,
    BodyPoint.elbow,
    BodyPoint.wrist,
    BodyPoint.hip,
    BodyPoint.knee,
    BodyPoint.ankle,
  ],
  angleLandmarks: (BodyPoint.shoulder, BodyPoint.elbow, BodyPoint.wrist),
  topAngleThresholdDeg: 155,
  bottomAngleThresholdDeg: 130,
  formChecks: [
    const RequiredLandmarksCheck(),
    const SideOrientationCheck(),
    const BodyInclinationCheck(
      from: BodyPoint.shoulder,
      to: BodyPoint.ankle,
      maxInclinationFromHorizontalDeg: 40,
    ),
    const AngleRangeCheck(
      landmarks: (BodyPoint.shoulder, BodyPoint.elbow, BodyPoint.wrist),
      minDeg: 50,
      maxDeg: 180,
    ),
    const BodyRigidityCheck(
      a: BodyPoint.shoulder,
      b: BodyPoint.hip,
      c: BodyPoint.ankle,
      absoluteMinDeg: 155,
      toleranceDeg: 18,
    ),
    const LegExtensionCheck(
      a: BodyPoint.hip,
      b: BodyPoint.knee,
      c: BodyPoint.ankle,
      absoluteMinDeg: 150,
      toleranceDeg: 20,
    ),
  ],
);
