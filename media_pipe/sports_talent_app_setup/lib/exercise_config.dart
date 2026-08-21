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
    this.topAngleThresholdDeg,
    this.bottomAngleThresholdDeg,
    required this.formChecks,
    this.landmarkConfidenceThreshold = kMinLandmarkLikelihood,
    this.emaAlpha = 0.4,
    this.stabilityWindow = const Duration(milliseconds: 1500),
    this.minRepInterval = const Duration(milliseconds: 600),
    this.maxUncertainFrames = 5,
    this.sustainedInvalidConfirmation = const Duration(milliseconds: 800),
    this.bottomEventValidator,
    this.topAngleReferenceKey,
    this.targetRomDeg,
    this.excessiveRomDeg,
    this.excessiveRomMessage,
  }) : assert(
         (topAngleThresholdDeg != null && bottomAngleThresholdDeg != null) ||
             (topAngleReferenceKey != null && targetRomDeg != null),
         'Provide either fixed topAngleThresholdDeg/bottomAngleThresholdDeg, '
         'or a topAngleReferenceKey + targetRomDeg pair for a calibrated '
         'relative-ROM threshold.',
       );

  final String name;
  final String setupInstruction;

  /// All landmarks that must be confidently visible on one side for a frame
  /// to be usable at all.
  final List<BodyPoint> requiredPoints;

  /// Triplet driving the primary rep-cycle angle (e.g. shoulder-elbow-wrist
  /// for push-ups).
  final (BodyPoint, BodyPoint, BodyPoint) angleLandmarks;

  /// Angle at/above which the athlete counts as at the TOP of the cycle.
  /// Either this is set directly (a fixed, universal value - e.g. squats
  /// assume near-straight standing legs for every athlete), or it's left
  /// null and derived per-athlete instead via [topAngleReferenceKey] +
  /// [targetRomDeg].
  final double? topAngleThresholdDeg;

  /// Angle at/below which the athlete counts as at the BOTTOM of the cycle.
  /// Either set directly, or left null and derived as
  /// `topThreshold - targetRomDeg`.
  final double? bottomAngleThresholdDeg;

  final List<FormCheck> formChecks;
  final double landmarkConfidenceThreshold;
  final double emaAlpha;
  final Duration stabilityWindow;
  final Duration minRepInterval;

  /// Consecutive UNCERTAIN frames tolerated before escalating to INVALID
  /// and invalidating the current trajectory.
  final int maxUncertainFrames;

  /// How long a definite INVALID form status must persist continuously
  /// before the test-attempt lifecycle counts it as one confirmed
  /// violation. Shorter INVALID blips are treated as noise, not a
  /// violation.
  final Duration sustainedInvalidConfirmation;

  /// Optional event-triggered validator invoked once when `AngleCycleEngine`
  /// confirms a genuine BOTTOM event, to verify the movement represents
  /// meaningful whole-body motion rather than a local joint-angle
  /// manipulation. Null for exercises that don't need it (e.g. push-ups).
  final BottomEventValidator? bottomEventValidator;

  /// Reference key (see [AngleBaselineReferenceCheck]) holding the
  /// athlete's own calibrated baseline for [angleLandmarks], used as the
  /// TOP threshold when [topAngleThresholdDeg] is null. Required alongside
  /// [targetRomDeg] whenever the exercise's absolute starting angle isn't
  /// consistent across athletes/camera setups (e.g. Controlled Crunch),
  /// unlike squats/push-ups where a fixed universal angle is a reasonable
  /// assumption.
  final String? topAngleReferenceKey;

  /// Required relative angular change (in degrees) from the calibrated TOP
  /// baseline to reach the BOTTOM of the cycle, used to derive
  /// [bottomAngleThresholdDeg] when it's null. Ignored otherwise.
  final double? targetRomDeg;

  /// Advisory-only upper bound (in degrees) on relative angular change from
  /// the TOP baseline. Exceeding it during DESCENDING/BOTTOM never rejects
  /// the rep or feeds the warning/termination lifecycle - it only surfaces
  /// [excessiveRomMessage] in the status text, so athletes get feedback
  /// without a fragile absolute threshold silently ending their test. Null
  /// for exercises that don't need this signal.
  final double? excessiveRomDeg;

  /// Advisory message shown when [excessiveRomDeg] is exceeded.
  final String? excessiveRomMessage;
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

final ExerciseConfig squatExerciseConfig = ExerciseConfig(
  name: 'Squats',
  setupInstruction:
      'Stand sideways to the camera, keep your entire body visible from '
      'head to feet, feet about shoulder-width apart, arms extended '
      'naturally forward, and hold a standing position to calibrate.',
  requiredPoints: const [
    BodyPoint.shoulder,
    BodyPoint.hip,
    BodyPoint.knee,
    BodyPoint.ankle,
  ],
  angleLandmarks: (BodyPoint.hip, BodyPoint.knee, BodyPoint.ankle),
  topAngleThresholdDeg: 160,
  bottomAngleThresholdDeg: 100,
  formChecks: [
    const RequiredLandmarksCheck(),
    const SideOrientationCheck(),
    const TorsoOrientationCheck(
      from: BodyPoint.shoulder,
      to: BodyPoint.hip,
      maxLeanFromVerticalDeg: 45,
    ),
    const CalibrationAngleGateCheck(
      landmarks: (BodyPoint.hip, BodyPoint.knee, BodyPoint.ankle),
      minDeg: 160,
      failureReason: 'Stand up straight with knees near-straight to calibrate',
    ),
    const VerticalBaselineReferenceCheck(
      key: 'hipBaselineY',
      checkName: 'hip_baseline_reference',
      sampler: averageHipY,
    ),
    const VerticalBaselineReferenceCheck(
      key: 'shoulderBaselineY',
      checkName: 'shoulder_baseline_reference',
      sampler: averageShoulderY,
    ),
    const ScaleReferenceCheck(
      a: BodyPoint.hip,
      b: BodyPoint.ankle,
      key: 'scaleReferencePx',
    ),
  ],
  // Global movement invariant on top of the local knee-angle ROM above:
  // rejects a BOTTOM event that isn't backed by genuine downward hip travel
  // (e.g. raising one foot while staying essentially standing), or where
  // the apparent descent is primarily an upper-body fold. See
  // HipDisplacementValidator for the exact thresholds.
  bottomEventValidator: const HipDisplacementValidator(),
);

/// V1 target relative trunk-angle ROM (degrees) for a Controlled Crunch,
/// measured as the shoulder-hip-knee angle's change from the athlete's own
/// calibrated resting baseline. Biomechanics literature places a traditional
/// crunch's trunk ROM in roughly the 15-30 degree band - well short of a
/// full sit-up. This is the middle of that range, not a validated value:
/// tune after physical testing. Kept as the single named constant driving
/// the whole exercise rather than scattered through the config below.
const double _kCrunchTargetRomDegrees = 20;

/// Advisory-only upper bound (degrees) on relative trunk-angle change for a
/// Controlled Crunch - past this the movement reads as excessive/possibly
/// transitioning into a full sit-up rather than a controlled partial curl.
/// Deliberately well above [_kCrunchTargetRomDegrees] so a normal athlete
/// slightly overshooting the target ROM isn't flagged; only tune this
/// tighter after physical testing shows it's needed.
const double _kCrunchExcessiveRomDegrees = 45;

/// Posture-gate tolerance (degrees): how far the shoulder->hip line may
/// deviate from perfectly horizontal and still count as a valid supine
/// starting posture. Supine reads near 0 degrees, standing near 90 degrees,
/// so this leaves a large geometric margin between the two while still
/// tolerating reasonable camera tilt - a standing athlete (even leaning
/// forward) should not be able to satisfy this. Chosen from the middle of
/// the requested 20-30 degree range, tighter than the 40-45 degree
/// tolerances used elsewhere (Push-up plank, Squat torso lean) since those
/// only need to reject clearly abnormal form, not distinguish two entirely
/// different body orientations. Single named constant so it's easy to
/// retune after physical testing without hunting through the config below.
const double _kCrunchMaxSupineInclinationFromHorizontalDeg = 25;

final ExerciseConfig controlledCrunchExerciseConfig = ExerciseConfig(
  name: 'Controlled Crunch',
  setupInstruction:
      'Lie down on your back and position yourself side-on to the camera, '
      'knees bent naturally, keeping your shoulder, hip, and knee all '
      'visible. Keep the phone upright (portrait) and stationary, and hold '
      'still in the relaxed starting position to calibrate.',
  requiredPoints: const [
    BodyPoint.shoulder,
    BodyPoint.hip,
    BodyPoint.knee,
  ],
  // Trunk-flexion angle at the hip vertex: shoulder-hip-knee. Curling up
  // moves the shoulder toward the knee, decreasing this angle - the same
  // "large angle = TOP, smaller angle = BOTTOM" direction AngleCycleEngine
  // already uses for push-ups and squats.
  angleLandmarks: (BodyPoint.shoulder, BodyPoint.hip, BodyPoint.knee),
  // No fixed topAngleThresholdDeg/bottomAngleThresholdDeg: unlike a squat's
  // standing legs, a supine resting trunk angle isn't consistent across
  // athletes/camera setups, so the TOP threshold is the athlete's own
  // calibrated baseline and BOTTOM is derived as a relative ROM below it.
  topAngleReferenceKey: 'trunkAngleBaselineDeg',
  targetRomDeg: _kCrunchTargetRomDegrees,
  excessiveRomDeg: _kCrunchExcessiveRomDegrees,
  excessiveRomMessage: 'Excessive movement - keep this a controlled partial crunch, not a sit-up',
  formChecks: [
    const RequiredLandmarksCheck(),
    const SideOrientationCheck(),
    // Posture gate: requires a genuine supine starting position (shoulder->
    // hip line near horizontal) before calibration is allowed to begin or
    // complete, and continues to enforce it once tracking - a standing
    // athlete, even one bending their torso forward, must never satisfy
    // this. Evaluated every frame like the other checks below, so it's
    // folded into the same stability-window gate during calibration and the
    // same invalidate/warning lifecycle once READY.
    const BodyInclinationCheck(
      from: BodyPoint.shoulder,
      to: BodyPoint.hip,
      maxInclinationFromHorizontalDeg: _kCrunchMaxSupineInclinationFromHorizontalDeg,
      invalidReason: 'Lie down on your back, side-on to the camera',
    ),
    // Broad plausibility floor/ceiling, independent of the tight calibrated
    // ROM thresholds that actually drive the rep cycle.
    const AngleRangeCheck(
      landmarks: (BodyPoint.shoulder, BodyPoint.hip, BodyPoint.knee),
      minDeg: 30,
      maxDeg: 180,
    ),
    const AngleBaselineReferenceCheck(
      landmarks: (BodyPoint.shoulder, BodyPoint.hip, BodyPoint.knee),
      key: 'trunkAngleBaselineDeg',
      checkName: 'trunk_angle_baseline_reference',
    ),
  ],
);
