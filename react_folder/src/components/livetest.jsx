/**
 * LiveTest — real-time exercise assessment with webcam + MediaPipe.
 *
 * Equivalent of Flutter's LiveTestScreen: captures webcam frames,
 * runs PoseLandmarker, feeds landmarks into the exercise engine,
 * and renders a skeleton overlay + status panel.
 */
import { useEffect, useRef, useState, useCallback } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import { getPoseLandmarker, disposePoseLandmarker } from '../mediapipe/poseDetector.js';
import { drawSkeleton } from '../mediapipe/skeletonRenderer.js';
import { ExerciseType } from '../mediapipe/engines/exerciseEngine.js';
import { AngleCycleEngine } from '../mediapipe/engines/angleCycleEngine.js';
import { pushUpConfig, squatConfig, controlledCrunchConfig } from '../mediapipe/engines/exerciseConfig.js';
import { WallSitEngine } from '../mediapipe/engines/wallSitEngine.js';
import { PlankEngine } from '../mediapipe/engines/plankEngine.js';
import { VerticalJumpEngine } from '../mediapipe/engines/verticalJumpEngine.js';
import './livetest.css';

const EXERCISE_LABELS = {
  [ExerciseType.PUSH_UP]: 'Push-ups',
  [ExerciseType.SQUAT]: 'Squats',
  [ExerciseType.CONTROLLED_CRUNCH]: 'Controlled Crunch',
  [ExerciseType.WALL_SIT]: 'Wall-Sit Hold',
  [ExerciseType.PLANK]: 'Straight-Arm Plank',
  [ExerciseType.VERTICAL_JUMP]: 'Standing Vertical Jump',
};

function createEngine(type, userHeightCm) {
  switch (type) {
    case ExerciseType.PUSH_UP: return new AngleCycleEngine(pushUpConfig);
    case ExerciseType.SQUAT: return new AngleCycleEngine(squatConfig);
    case ExerciseType.CONTROLLED_CRUNCH: return new AngleCycleEngine(controlledCrunchConfig);
    case ExerciseType.WALL_SIT: return new WallSitEngine();
    case ExerciseType.PLANK: return new PlankEngine();
    case ExerciseType.VERTICAL_JUMP: return new VerticalJumpEngine(userHeightCm || 170);
    default: return null;
  }
}

export default function LiveTest() {
  const { exerciseType } = useParams();
  const navigate = useNavigate();

  const videoRef = useRef(null);
  const canvasRef = useRef(null);
  const engineRef = useRef(null);
  const landmarkerRef = useRef(null);
  const rafRef = useRef(null);
  const streamRef = useRef(null);
  const lastTimestampRef = useRef(-1);

  const [loading, setLoading] = useState(true);
  const [statusText, setStatusText] = useState({ primary: 'Initializing...', secondary: '' });
  const [bodyVisible, setBodyVisible] = useState(true);
  const [formClass, setFormClass] = useState('');

  // Height modal for vertical jump
  const [showHeightModal, setShowHeightModal] = useState(exerciseType === ExerciseType.VERTICAL_JUMP);
  const [heightInput, setHeightInput] = useState('170');

  const handleStop = useCallback(() => {
    navigate(-1);
  }, [navigate]);

  const handleHeightConfirm = useCallback(() => {
    const cm = parseFloat(heightInput);
    if (isNaN(cm) || cm < 50 || cm > 250) return;
    setShowHeightModal(false);
  }, [heightInput]);

  // ── Init: webcam + MediaPipe model + engine + detection loop ──────────
  useEffect(() => {
    if (showHeightModal) return;

    let cancelled = false;
    const userHeightCm = parseFloat(heightInput) || 170;

    const engine = createEngine(exerciseType, userHeightCm);
    if (!engine) {
      setStatusText({ primary: 'Unknown exercise type', secondary: '' });
      setLoading(false);
      return;
    }
    engineRef.current = engine;

    async function init() {
      try {
        // Start webcam
        const stream = await navigator.mediaDevices.getUserMedia({
          video: { facingMode: 'user', width: { ideal: 1280 }, height: { ideal: 720 } },
          audio: false,
        });
        if (cancelled) { stream.getTracks().forEach(t => t.stop()); return; }
        streamRef.current = stream;

        const video = videoRef.current;
        video.srcObject = stream;
        await video.play();

        // Load MediaPipe
        const landmarker = await getPoseLandmarker();
        if (cancelled) return;
        landmarkerRef.current = landmarker;
        setLoading(false);

        // Detection loop
        function processFrame() {
          if (cancelled) return;
          rafRef.current = requestAnimationFrame(processFrame);

          if (!video || video.readyState < 2) return;
          const now = performance.now();
          // Skip if same timestamp (requestAnimationFrame can fire faster than video frames)
          if (now === lastTimestampRef.current) return;
          lastTimestampRef.current = now;

          // Resize canvas to match video
          const canvas = canvasRef.current;
          if (!canvas) return;
          if (canvas.width !== video.videoWidth || canvas.height !== video.videoHeight) {
            canvas.width = video.videoWidth;
            canvas.height = video.videoHeight;
          }

          // Detect pose
          let landmarks = null;
          try {
            const result = landmarker.detectForVideo(video, now);
            if (result?.landmarks?.length > 0) {
              landmarks = result.landmarks[0];
            }
          } catch (e) {
            // Swallow detection errors (can happen during init)
          }

          // Feed engine
          engine.processLandmarks(landmarks);

          // Draw skeleton
          const ctx = canvas.getContext('2d');
          drawSkeleton(ctx, landmarks, canvas.width, canvas.height, {
            mirror: true,
            groundGuideY: engine.groundGuideY,
          });

          // Update React state (throttled — only every frame)
          const status = engine.status;
          setStatusText({ primary: status.primaryText, secondary: status.secondaryText || '' });
          setBodyVisible(status.isBodyVisible);

          // Determine form class from secondary text
          const sec = (status.secondaryText || '').toLowerCase();
          if (sec.includes('invalid') || sec.includes('warning') || sec.includes('terminated') || sec.includes('ended')) {
            setFormClass('form-invalid');
          } else if (sec.includes('uncertain') || sec.includes('calibrat') || sec.includes('hold still')) {
            setFormClass('form-uncertain');
          } else {
            setFormClass('form-valid');
          }
        }

        rafRef.current = requestAnimationFrame(processFrame);
      } catch (err) {
        console.error('LiveTest init error:', err);
        setStatusText({ primary: 'Camera access denied', secondary: err.message });
        setLoading(false);
      }
    }

    init();

    return () => {
      cancelled = true;
      if (rafRef.current) cancelAnimationFrame(rafRef.current);
      if (streamRef.current) streamRef.current.getTracks().forEach(t => t.stop());
    };
  }, [exerciseType, showHeightModal, heightInput]);

  // ── Height modal ──────────────────────────────────────────────────────
  if (showHeightModal) {
    return (
      <div className="livetest-height-modal-overlay">
        <div className="livetest-height-modal">
          <h3>Enter Your Height</h3>
          <div>
            <label>Height (cm)</label>
            <input
              type="number"
              value={heightInput}
              onChange={(e) => setHeightInput(e.target.value)}
              min="50"
              max="250"
              autoFocus
              onKeyDown={(e) => e.key === 'Enter' && handleHeightConfirm()}
            />
          </div>
          <div className="livetest-height-modal-actions">
            <button className="cancel" onClick={handleStop}>Cancel</button>
            <button className="confirm" onClick={handleHeightConfirm}>Start Test</button>
          </div>
        </div>
      </div>
    );
  }

  // ── Main UI ───────────────────────────────────────────────────────────
  return (
    <div className="livetest-root">
      {/* Top bar */}
      <div className="livetest-topbar">
        <button className="livetest-back-btn" onClick={handleStop} aria-label="Go back">
          ←
        </button>
        <span className="livetest-title">{EXERCISE_LABELS[exerciseType] || exerciseType}</span>
        {loading && (
          <span className="livetest-loading-badge">Loading model…</span>
        )}
      </div>

      {/* Camera + skeleton overlay */}
      <div className="livetest-camera-container">
        <video ref={videoRef} className="livetest-video" playsInline muted />
        <canvas ref={canvasRef} className="livetest-canvas" />

        {loading && (
          <div className="livetest-placeholder">
            <div className="spinner" />
            <span>Initializing camera &amp; pose model…</span>
          </div>
        )}

        {!loading && !bodyVisible && (
          <div className="livetest-no-body-overlay">
            <div className="livetest-no-body-text">
              <span className="icon">👤</span>
              <span className="label">Body not detected — move into frame</span>
            </div>
          </div>
        )}
      </div>

      {/* Status panel */}
      <div className="livetest-status-panel">
        <div className="livetest-status-primary">{statusText.primary}</div>
        {statusText.secondary && (
          <div className={`livetest-status-secondary ${formClass}`}>
            {statusText.secondary}
          </div>
        )}
        <button className="livetest-stop-btn" onClick={handleStop}>
          Stop
        </button>
      </div>
    </div>
  );
}
