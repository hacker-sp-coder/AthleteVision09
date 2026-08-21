/**
 * Left/right body-side resolution — ported from sided_pose.dart.
 *
 * Side-view exercises need landmarks from one consistent side of the body.
 * This module picks the side with better landmark confidence and extracts
 * the required points for that side.
 */
import { LM, isLandmarkVisible, pixelDistance } from './poseUtils.js';

/** Named body landmarks relevant to side-view exercises. */
export const BodyPoint = Object.freeze({
  SHOULDER: 'shoulder',
  ELBOW: 'elbow',
  WRIST: 'wrist',
  HIP: 'hip',
  KNEE: 'knee',
  ANKLE: 'ankle',
});

/** Maps BodyPoint → [leftIndex, rightIndex] in MediaPipe landmarks. */
const BODY_POINT_INDICES = {
  [BodyPoint.SHOULDER]: [LM.LEFT_SHOULDER, LM.RIGHT_SHOULDER],
  [BodyPoint.ELBOW]: [LM.LEFT_ELBOW, LM.RIGHT_ELBOW],
  [BodyPoint.WRIST]: [LM.LEFT_WRIST, LM.RIGHT_WRIST],
  [BodyPoint.HIP]: [LM.LEFT_HIP, LM.RIGHT_HIP],
  [BodyPoint.KNEE]: [LM.LEFT_KNEE, LM.RIGHT_KNEE],
  [BodyPoint.ANKLE]: [LM.LEFT_ANKLE, LM.RIGHT_ANKLE],
};

/**
 * @typedef {Object} SidedPose
 * @property {Object.<string, Object>} points  Map of BodyPoint → landmark {x,y,z,visibility}
 * @property {boolean} isLeftSide
 */

/**
 * Tries to extract required body points from one side.
 * @returns {SidedPose|null}
 */
function tryExtract(landmarks, requiredPoints, confidenceThreshold, useLeft) {
  const points = {};
  for (const point of requiredPoints) {
    const [leftIdx, rightIdx] = BODY_POINT_INDICES[point];
    const idx = useLeft ? leftIdx : rightIdx;
    const lm = landmarks[idx];
    if (!isLandmarkVisible(lm, confidenceThreshold)) return null;
    points[point] = lm;
  }
  return { points, isLeftSide: useLeft };
}

/**
 * Resolves which side (left/right) of the body faces the camera and
 * extracts the required points for that side.
 *
 * If preferLeftSide is given and that side is still extractable, it's kept
 * to avoid frame-to-frame flip-flopping.
 *
 * @param {Array} landmarks  MediaPipe normalized landmarks array
 * @param {string[]} requiredPoints  Array of BodyPoint values
 * @param {number} confidenceThreshold
 * @param {boolean|null} preferLeftSide
 * @returns {SidedPose|null}
 */
export function resolveSidedPose(landmarks, requiredPoints, confidenceThreshold, preferLeftSide = null) {
  if (preferLeftSide != null) {
    const preferred = tryExtract(landmarks, requiredPoints, confidenceThreshold, preferLeftSide);
    if (preferred) return preferred;
  }

  const left = tryExtract(landmarks, requiredPoints, confidenceThreshold, true);
  const right = tryExtract(landmarks, requiredPoints, confidenceThreshold, false);

  if (left && !right) return left;
  if (right && !left) return right;
  if (left && right) {
    const leftShoulder = left.points[BodyPoint.SHOULDER]?.visibility ?? 0;
    const leftHip = left.points[BodyPoint.HIP]?.visibility ?? 0;
    const rightShoulder = right.points[BodyPoint.SHOULDER]?.visibility ?? 0;
    const rightHip = right.points[BodyPoint.HIP]?.visibility ?? 0;
    return (leftShoulder + leftHip) >= (rightShoulder + rightHip) ? left : right;
  }
  return null;
}

/**
 * Returns the raw MediaPipe landmark index for the "other" shoulder
 * (the one not on the sided pose's primary side).
 */
export function otherShoulderIndex(isLeftSide) {
  return isLeftSide ? LM.RIGHT_SHOULDER : LM.LEFT_SHOULDER;
}
