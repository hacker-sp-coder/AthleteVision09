/**
 * Pose geometry utilities — ported from the Flutter pose_utils.dart.
 *
 * MediaPipe web PoseLandmarker returns landmarks as normalized [0,1]
 * coordinates with `visibility` scores. This module maps landmark indices
 * to named constants and provides the same helper functions the Flutter
 * codebase uses.
 */

// ─── MediaPipe Pose Landmark Indices ─────────────────────────────────────
// https://developers.google.com/mediapipe/solutions/vision/pose_landmarker
export const LM = Object.freeze({
  NOSE: 0,
  LEFT_EYE_INNER: 1,
  LEFT_EYE: 2,
  LEFT_EYE_OUTER: 3,
  RIGHT_EYE_INNER: 4,
  RIGHT_EYE: 5,
  RIGHT_EYE_OUTER: 6,
  LEFT_EAR: 7,
  RIGHT_EAR: 8,
  MOUTH_LEFT: 9,
  MOUTH_RIGHT: 10,
  LEFT_SHOULDER: 11,
  RIGHT_SHOULDER: 12,
  LEFT_ELBOW: 13,
  RIGHT_ELBOW: 14,
  LEFT_WRIST: 15,
  RIGHT_WRIST: 16,
  LEFT_PINKY: 17,
  RIGHT_PINKY: 18,
  LEFT_INDEX: 19,
  RIGHT_INDEX: 20,
  LEFT_THUMB: 21,
  RIGHT_THUMB: 22,
  LEFT_HIP: 23,
  RIGHT_HIP: 24,
  LEFT_KNEE: 25,
  RIGHT_KNEE: 26,
  LEFT_ANKLE: 27,
  RIGHT_ANKLE: 28,
  LEFT_HEEL: 29,
  RIGHT_HEEL: 30,
  LEFT_FOOT_INDEX: 31,
  RIGHT_FOOT_INDEX: 32,
});

/** Minimum visibility score to trust a landmark. */
export const MIN_LANDMARK_VISIBILITY = 0.6;

/**
 * Empirical correction factor applied to the raw nose-to-ankle pixel span
 * to approximate true standing height (top-of-head to floor).
 */
export const HEIGHT_CORRECTION_FACTOR = 1.10;

/** Landmarks required for a "full body visible" check. */
export const FULL_BODY_LANDMARKS = [
  LM.NOSE,
  LM.LEFT_SHOULDER, LM.RIGHT_SHOULDER,
  LM.LEFT_HIP, LM.RIGHT_HIP,
  LM.LEFT_KNEE, LM.RIGHT_KNEE,
  LM.LEFT_ANKLE, LM.RIGHT_ANKLE,
];

// ─── Helpers ─────────────────────────────────────────────────────────────

/**
 * Whether a single landmark is confidently visible.
 * MediaPipe web landmarks have { x, y, z, visibility }.
 */
export function isLandmarkVisible(landmark, threshold = MIN_LANDMARK_VISIBILITY) {
  return landmark != null && (landmark.visibility ?? 0) >= threshold;
}

/**
 * Angle (degrees) at vertex b, formed by a-b-c. 2D only (x, y).
 * a, b, c are objects with { x, y }.
 */
export function angleBetweenPoints(a, b, c) {
  const v1x = a.x - b.x;
  const v1y = a.y - b.y;
  const v2x = c.x - b.x;
  const v2y = c.y - b.y;

  const dot = v1x * v2x + v1y * v2y;
  const mag1 = Math.sqrt(v1x * v1x + v1y * v1y);
  const mag2 = Math.sqrt(v2x * v2x + v2y * v2y);
  if (mag1 === 0 || mag2 === 0) return 0;

  const cosAngle = Math.max(-1, Math.min(1, dot / (mag1 * mag2)));
  return Math.acos(cosAngle) * (180 / Math.PI);
}

/** 2D Euclidean pixel distance between two landmarks. */
export function pixelDistance(a, b) {
  const dx = a.x - b.x;
  const dy = a.y - b.y;
  return Math.sqrt(dx * dx + dy * dy);
}

// ─── Bilateral averages ──────────────────────────────────────────────────
// These work on the raw landmarks array from MediaPipe.

function _bilateralAverage(landmarks, leftIdx, rightIdx, axis, threshold) {
  const left = landmarks[leftIdx];
  const right = landmarks[rightIdx];
  const lv = isLandmarkVisible(left, threshold);
  const rv = isLandmarkVisible(right, threshold);
  if (lv && rv) return (left[axis] + right[axis]) / 2;
  if (lv) return left[axis];
  if (rv) return right[axis];
  return null;
}

export function averageAnkleY(landmarks, threshold = MIN_LANDMARK_VISIBILITY) {
  return _bilateralAverage(landmarks, LM.LEFT_ANKLE, LM.RIGHT_ANKLE, 'y', threshold);
}

export function leftAnkleY(landmarks, threshold = MIN_LANDMARK_VISIBILITY) {
  const lm = landmarks[LM.LEFT_ANKLE];
  return isLandmarkVisible(lm, threshold) ? lm.y : null;
}

export function rightAnkleY(landmarks, threshold = MIN_LANDMARK_VISIBILITY) {
  const lm = landmarks[LM.RIGHT_ANKLE];
  return isLandmarkVisible(lm, threshold) ? lm.y : null;
}

export function averageHipY(landmarks, threshold = MIN_LANDMARK_VISIBILITY) {
  return _bilateralAverage(landmarks, LM.LEFT_HIP, LM.RIGHT_HIP, 'y', threshold);
}

export function averageHipX(landmarks, threshold = MIN_LANDMARK_VISIBILITY) {
  return _bilateralAverage(landmarks, LM.LEFT_HIP, LM.RIGHT_HIP, 'x', threshold);
}

export function averageShoulderY(landmarks, threshold = MIN_LANDMARK_VISIBILITY) {
  return _bilateralAverage(landmarks, LM.LEFT_SHOULDER, LM.RIGHT_SHOULDER, 'y', threshold);
}

/**
 * Checks that all required landmarks are visible with confidence >= threshold.
 */
export function isFullBodyVisible(landmarks, threshold = MIN_LANDMARK_VISIBILITY, required = FULL_BODY_LANDMARKS) {
  for (const idx of required) {
    if (!isLandmarkVisible(landmarks[idx], threshold)) return false;
  }
  return true;
}

/**
 * Nose-to-average-ankle pixel distance, proxy for standing height in pixels.
 */
export function estimateStandingHeightPixels(landmarks, threshold = MIN_LANDMARK_VISIBILITY) {
  const nose = landmarks[LM.NOSE];
  if (!isLandmarkVisible(nose, threshold)) return null;
  const ankleY = averageAnkleY(landmarks, threshold);
  if (ankleY == null) return null;
  return Math.abs(ankleY - nose.y);
}

/**
 * Centimeters per pixel, derived from measured pixel height and real height.
 */
export function cmPerPixel(heightPixels, realHeightCm) {
  if (heightPixels <= 0) return null;
  return realHeightCm / (heightPixels * HEIGHT_CORRECTION_FACTOR);
}
