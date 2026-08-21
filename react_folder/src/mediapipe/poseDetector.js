/**
 * MediaPipe PoseLandmarker initialization and management.
 *
 * Provides a singleton-style async factory for the browser-based
 * PoseLandmarker from @mediapipe/tasks-vision.
 */
import { PoseLandmarker, FilesetResolver } from '@mediapipe/tasks-vision';

const WASM_CDN = 'https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision/wasm';
const MODEL_URL =
  'https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_lite/float16/1/pose_landmarker_lite.task';

let _instance = null;
let _creating = null;

/**
 * Creates (or returns the existing) PoseLandmarker instance.
 * Thread-safe against concurrent callers — only one creation runs.
 */
export async function getPoseLandmarker() {
  if (_instance) return _instance;
  if (_creating) return _creating;

  _creating = (async () => {
    const vision = await FilesetResolver.forVisionTasks(WASM_CDN);
    _instance = await PoseLandmarker.createFromOptions(vision, {
      baseOptions: { modelAssetPath: MODEL_URL },
      runningMode: 'VIDEO',
      numPoses: 1,
      minPoseDetectionConfidence: 0.5,
      minPosePresenceConfidence: 0.5,
      minTrackingConfidence: 0.5,
    });
    _creating = null;
    return _instance;
  })();

  return _creating;
}

/**
 * Disposes the current PoseLandmarker instance (if any).
 */
export function disposePoseLandmarker() {
  if (_instance) {
    _instance.close();
    _instance = null;
  }
}
