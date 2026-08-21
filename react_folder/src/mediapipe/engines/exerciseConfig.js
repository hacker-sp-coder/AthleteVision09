/**
 * Exercise-specific configurations — ported from exercise_config.dart.
 *
 * Each config defines which landmarks, angle thresholds, and form checks
 * an exercise uses. Consumed by AngleCycleEngine for rep-based exercises.
 */
import { BodyPoint } from '../sidedPose.js';
import { averageHipY, averageShoulderY, MIN_LANDMARK_VISIBILITY } from '../poseUtils.js';
import {
  RequiredLandmarksCheck,
  SideOrientationCheck,
  BodyInclinationCheck,
  AngleRangeCheck,
  BodyRigidityCheck,
  TorsoOrientationCheck,
  CalibrationAngleGateCheck,
  LegExtensionCheck,
  VerticalBaselineReferenceCheck,
  AngleBaselineReferenceCheck,
  ScaleReferenceCheck,
  HipDisplacementValidator,
} from './formCheck.js';

/**
 * Configuration object for an angle-cycle exercise.
 */
export class ExerciseConfig {
  constructor({
    name,
    setupInstruction,
    requiredPoints,
    angleLandmarks,
    topAngleThresholdDeg = null,
    bottomAngleThresholdDeg = null,
    formChecks,
    landmarkConfidenceThreshold = MIN_LANDMARK_VISIBILITY,
    emaAlpha = 0.4,
    stabilityWindowMs = 1500,
    minRepIntervalMs = 600,
    maxUncertainFrames = 5,
    sustainedInvalidConfirmationMs = 800,
    bottomEventValidator = null,
    topAngleReferenceKey = null,
    targetRomDeg = null,
    excessiveRomDeg = null,
    excessiveRomMessage = null,
  }) {
    this.name = name;
    this.setupInstruction = setupInstruction;
    this.requiredPoints = requiredPoints;
    this.angleLandmarks = angleLandmarks; // [BodyPoint, BodyPoint, BodyPoint]
    this.topAngleThresholdDeg = topAngleThresholdDeg;
    this.bottomAngleThresholdDeg = bottomAngleThresholdDeg;
    this.formChecks = formChecks;
    this.landmarkConfidenceThreshold = landmarkConfidenceThreshold;
    this.emaAlpha = emaAlpha;
    this.stabilityWindowMs = stabilityWindowMs;
    this.minRepIntervalMs = minRepIntervalMs;
    this.maxUncertainFrames = maxUncertainFrames;
    this.sustainedInvalidConfirmationMs = sustainedInvalidConfirmationMs;
    this.bottomEventValidator = bottomEventValidator;
    this.topAngleReferenceKey = topAngleReferenceKey;
    this.targetRomDeg = targetRomDeg;
    this.excessiveRomDeg = excessiveRomDeg;
    this.excessiveRomMessage = excessiveRomMessage;
  }
}

// ─── Push-up Config ──────────────────────────────────────────────────────

export const pushUpConfig = new ExerciseConfig({
  name: 'Push-ups',
  setupInstruction:
    'Turn sideways to the camera, keep your entire body visible, and get into the starting push-up position.',
  requiredPoints: [
    BodyPoint.SHOULDER, BodyPoint.ELBOW, BodyPoint.WRIST,
    BodyPoint.HIP, BodyPoint.KNEE, BodyPoint.ANKLE,
  ],
  angleLandmarks: [BodyPoint.SHOULDER, BodyPoint.ELBOW, BodyPoint.WRIST],
  topAngleThresholdDeg: 155,
  bottomAngleThresholdDeg: 130,
  formChecks: [
    new RequiredLandmarksCheck(),
    new SideOrientationCheck(),
    new BodyInclinationCheck({
      from: BodyPoint.SHOULDER, to: BodyPoint.ANKLE,
      maxInclinationFromHorizontalDeg: 40,
    }),
    new AngleRangeCheck({
      landmarks: [BodyPoint.SHOULDER, BodyPoint.ELBOW, BodyPoint.WRIST],
      minDeg: 50, maxDeg: 180,
    }),
    new BodyRigidityCheck({
      a: BodyPoint.SHOULDER, b: BodyPoint.HIP, c: BodyPoint.ANKLE,
      absoluteMinDeg: 155, toleranceDeg: 18,
    }),
    new LegExtensionCheck({
      a: BodyPoint.HIP, b: BodyPoint.KNEE, c: BodyPoint.ANKLE,
      absoluteMinDeg: 150, toleranceDeg: 20,
    }),
  ],
});

// ─── Squat Config ────────────────────────────────────────────────────────

export const squatConfig = new ExerciseConfig({
  name: 'Squats',
  setupInstruction:
    'Stand sideways to the camera, keep your entire body visible from head to feet, ' +
    'feet about shoulder-width apart, arms extended naturally forward, and hold a standing position to calibrate.',
  requiredPoints: [
    BodyPoint.SHOULDER, BodyPoint.HIP, BodyPoint.KNEE, BodyPoint.ANKLE,
  ],
  angleLandmarks: [BodyPoint.HIP, BodyPoint.KNEE, BodyPoint.ANKLE],
  topAngleThresholdDeg: 160,
  bottomAngleThresholdDeg: 100,
  formChecks: [
    new RequiredLandmarksCheck(),
    new SideOrientationCheck(),
    new TorsoOrientationCheck({
      from: BodyPoint.SHOULDER, to: BodyPoint.HIP,
      maxLeanFromVerticalDeg: 45,
    }),
    new CalibrationAngleGateCheck({
      landmarks: [BodyPoint.HIP, BodyPoint.KNEE, BodyPoint.ANKLE],
      minDeg: 160,
      failureReason: 'Stand up straight with knees near-straight to calibrate',
    }),
    new VerticalBaselineReferenceCheck({
      key: 'hipBaselineY',
      checkName: 'hip_baseline_reference',
      sampler: averageHipY,
    }),
    new VerticalBaselineReferenceCheck({
      key: 'shoulderBaselineY',
      checkName: 'shoulder_baseline_reference',
      sampler: averageShoulderY,
    }),
    new ScaleReferenceCheck({
      a: BodyPoint.HIP, b: BodyPoint.ANKLE,
      key: 'scaleReferencePx',
    }),
  ],
  bottomEventValidator: new HipDisplacementValidator(),
});

// ─── Controlled Crunch Config ────────────────────────────────────────────

const CRUNCH_TARGET_ROM_DEG = 20;
const CRUNCH_EXCESSIVE_ROM_DEG = 45;
const CRUNCH_MAX_SUPINE_INCLINATION_DEG = 25;

export const controlledCrunchConfig = new ExerciseConfig({
  name: 'Controlled Crunch',
  setupInstruction:
    'Lie down on your back and position yourself side-on to the camera, ' +
    'knees bent naturally, keeping your shoulder, hip, and knee all visible. ' +
    'Keep the camera upright and stationary, and hold still in the relaxed starting position to calibrate.',
  requiredPoints: [BodyPoint.SHOULDER, BodyPoint.HIP, BodyPoint.KNEE],
  angleLandmarks: [BodyPoint.SHOULDER, BodyPoint.HIP, BodyPoint.KNEE],
  topAngleReferenceKey: 'trunkAngleBaselineDeg',
  targetRomDeg: CRUNCH_TARGET_ROM_DEG,
  excessiveRomDeg: CRUNCH_EXCESSIVE_ROM_DEG,
  excessiveRomMessage: 'Excessive movement - keep this a controlled partial crunch, not a sit-up',
  formChecks: [
    new RequiredLandmarksCheck(),
    new SideOrientationCheck(),
    new BodyInclinationCheck({
      from: BodyPoint.SHOULDER, to: BodyPoint.HIP,
      maxInclinationFromHorizontalDeg: CRUNCH_MAX_SUPINE_INCLINATION_DEG,
      invalidReason: 'Lie down on your back, side-on to the camera',
    }),
    new AngleRangeCheck({
      landmarks: [BodyPoint.SHOULDER, BodyPoint.HIP, BodyPoint.KNEE],
      minDeg: 30, maxDeg: 180,
    }),
    new AngleBaselineReferenceCheck({
      landmarks: [BodyPoint.SHOULDER, BodyPoint.HIP, BodyPoint.KNEE],
      key: 'trunkAngleBaselineDeg',
      checkName: 'trunk_angle_baseline_reference',
    }),
  ],
});
