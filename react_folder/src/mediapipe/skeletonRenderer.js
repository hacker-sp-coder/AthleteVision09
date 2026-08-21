/**
 * Skeleton overlay renderer — ported from pose_painter.dart.
 *
 * Draws MediaPipe pose landmarks and stick-figure skeleton on an HTML5
 * <canvas> overlay. MediaPipe web returns normalized [0,1] coordinates,
 * so mapping is simpler than the Flutter version (no sensor rotation).
 */
import { LM } from './poseUtils.js';

const OVERLAY_MIN_VISIBILITY = 0.5;

/** Skeleton connection pairs (landmark index pairs). */
const SKELETON_CONNECTIONS = [
  [LM.NOSE, LM.LEFT_SHOULDER],
  [LM.NOSE, LM.RIGHT_SHOULDER],
  [LM.LEFT_SHOULDER, LM.RIGHT_SHOULDER],
  [LM.LEFT_SHOULDER, LM.LEFT_ELBOW],
  [LM.LEFT_ELBOW, LM.LEFT_WRIST],
  [LM.RIGHT_SHOULDER, LM.RIGHT_ELBOW],
  [LM.RIGHT_ELBOW, LM.RIGHT_WRIST],
  [LM.LEFT_SHOULDER, LM.LEFT_HIP],
  [LM.RIGHT_SHOULDER, LM.RIGHT_HIP],
  [LM.LEFT_HIP, LM.RIGHT_HIP],
  [LM.LEFT_HIP, LM.LEFT_KNEE],
  [LM.LEFT_KNEE, LM.LEFT_ANKLE],
  [LM.RIGHT_HIP, LM.RIGHT_KNEE],
  [LM.RIGHT_KNEE, LM.RIGHT_ANKLE],
];

/**
 * @param {CanvasRenderingContext2D} ctx
 * @param {Array} landmarks  MediaPipe normalized landmarks
 * @param {number} canvasWidth
 * @param {number} canvasHeight
 * @param {Object} [options]
 * @param {number|null} [options.groundGuideY]  Normalized Y for ground guide line
 * @param {boolean} [options.mirror]  Whether to mirror horizontally (for front camera)
 */
export function drawSkeleton(ctx, landmarks, canvasWidth, canvasHeight, options = {}) {
  const { groundGuideY = null, mirror = true } = options;

  ctx.clearRect(0, 0, canvasWidth, canvasHeight);

  if (!landmarks || landmarks.length === 0) return;

  const toX = (nx) => mirror ? (1 - nx) * canvasWidth : nx * canvasWidth;
  const toY = (ny) => ny * canvasHeight;

  const getPoint = (idx) => {
    const lm = landmarks[idx];
    if (!lm || (lm.visibility ?? 0) < OVERLAY_MIN_VISIBILITY) return null;
    return { x: toX(lm.x), y: toY(lm.y) };
  };

  // Draw connections (cyan lines)
  ctx.strokeStyle = '#00ffff';
  ctx.lineWidth = 3;
  ctx.lineCap = 'round';
  for (const [idxA, idxB] of SKELETON_CONNECTIONS) {
    const a = getPoint(idxA);
    const b = getPoint(idxB);
    if (!a || !b) continue;
    ctx.beginPath();
    ctx.moveTo(a.x, a.y);
    ctx.lineTo(b.x, b.y);
    ctx.stroke();
  }

  // Draw landmark dots (yellow)
  ctx.fillStyle = '#ffff00';
  for (let i = 0; i < landmarks.length; i++) {
    const pt = getPoint(i);
    if (!pt) continue;
    ctx.beginPath();
    ctx.arc(pt.x, pt.y, 5, 0, 2 * Math.PI);
    ctx.fill();
  }

  // Draw ground guide line (orange dashed)
  if (groundGuideY != null) {
    const y = toY(groundGuideY);
    ctx.strokeStyle = '#ffaa00';
    ctx.lineWidth = 2;
    ctx.setLineDash([12, 8]);
    ctx.beginPath();
    ctx.moveTo(0, y);
    ctx.lineTo(canvasWidth, y);
    ctx.stroke();
    ctx.setLineDash([]);
  }
}
