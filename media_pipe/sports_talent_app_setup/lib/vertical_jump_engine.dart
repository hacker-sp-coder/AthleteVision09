import 'package:flutter/foundation.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import 'exercise_engine.dart';
import 'pose_utils.dart';

/// Why a confirmed jump (a genuine airborne -> landing event) was rejected.
/// Deliberately small - only the failure modes actually reachable once an
/// attempt requires real airborne evidence to exist at all.
enum JumpInvalidReason {
  /// Horizontal hip displacement from the calibrated baseline exceeded
  /// tolerance during the confirmed airborne window.
  excessiveDrift,

  /// The measurement trajectory couldn't be trusted: either landmark
  /// tracking was lost for too long during the confirmed airborne window,
  /// or no usable hip sample was ever collected during it.
  insufficientData,

  /// The hip-to-ankle vertical span collapsed too far below the calibrated
  /// standing span during the confirmed airborne window - evidence of a
  /// deliberate leg tuck rather than natural knee flexion. Guards against
  /// hip-based height being inflated by body-configuration change rather
  /// than genuine vertical displacement.
  legConfigurationChange,
}

class JumpAttemptResult {
  const JumpAttemptResult({
    required this.attemptNumber,
    required this.isValid,
    this.invalidReason,
    this.heightCm,
  });

  final int attemptNumber;
  final bool isValid;
  final JumpInvalidReason? invalidReason;
  final double? heightCm;
}

enum _JumpState { calibrating, ready, airborne, awaitingBaseline, testComplete }

/// Bounded recent-sample window for one foot's raw ankle Y. Used to derive a
/// short windowed rise (oldest sample vs newest) as a lightweight,
/// direction-and-rate signal, instead of comparing a single instantaneous
/// frame to a fixed baseline. A tracking gap longer than [maxGap] discards
/// the window before the next sample lands, so a stale old sample can never
/// be paired with a fresh one to fabricate a "rise" out of a real gap.
class _AnkleTracker {
  final List<(DateTime, double)> _window = [];
  DateTime? _lastSeen;

  void push(double? y, DateTime now, {required Duration maxGap, required int windowSize}) {
    if (y == null) return;
    if (_lastSeen != null && now.difference(_lastSeen!) > maxGap) {
      _window.clear();
    }
    _window.add((now, y));
    if (_window.length > windowSize) _window.removeAt(0);
    _lastSeen = now;
  }

  /// Oldest retained sample's Y minus the newest sample's Y: positive means
  /// the foot has risen since the window's oldest sample. Null until at
  /// least two samples have been collected.
  double? get rise {
    if (_window.length < 2) return null;
    return _window.first.$2 - _window.last.$2;
  }

  void reset() {
    _window.clear();
    _lastSeen = null;
  }
}

/// Standing vertical jump test: three maximum-effort attempts, scored on the
/// best valid jump height.
///
/// Core architectural rule: FEET decide events, HIP measures performance.
/// Takeoff and landing are decided purely from left/right ankle trajectory
/// relative to the calibrated ground baseline - the hip is never consulted
/// for those decisions. The hip is used only during an already-confirmed
/// airborne window, to find the apex (a retrospective minimum) and compute
/// jump height, and to validate horizontal drift. This keeps event
/// detection and performance measurement from ever being conflated.
///
/// There is no real-time "attempt started" event. The engine continuously
/// observes the athlete while [_JumpState.ready], and an attempt only comes
/// into existence retrospectively, once a genuine ankle-based takeoff and
/// landing have both been confirmed. Standing still, swaying, translating
/// toward/away from the camera, or squatting down and back up all leave the
/// engine in [_JumpState.ready] forever - nothing is consumed.
///
/// The jump algorithm only depends on four landmarks: left ankle, right
/// ankle, left hip, right hip. Everything else (nose, shoulders, knees,
/// wrists, ...) may still be rendered for visualization but is never
/// required - a low-confidence nose or knee can no longer invalidate an
/// otherwise perfectly usable jump measurement. The one exception is
/// calibration, which is a one-time setup snapshot: it still uses the
/// existing full-body visibility check (to confirm the athlete is properly
/// framed before anything is captured) and the existing nose-to-ankle scale
/// infrastructure (to convert pixel displacement to real-world height).
/// Neither becomes an ongoing gate once calibration hands off its fixed
/// reference values.
///
/// Three separate pose-data paths exist by design: the CURRENT pose (what
/// ML Kit returned this frame - possibly null), the DISPLAY pose (owned by
/// [LiveTestScreen], may briefly hold a recent pose for visual smoothness),
/// and the MEASUREMENT trajectory (the raw per-frame samples this engine
/// actually collects). This engine only ever receives the current pose -
/// the display-hold behavior lives entirely outside this class - and never
/// duplicates a missing frame's value: a gap is a gap, not a repeated or
/// interpolated sample. Short gaps are tolerated at every stage; a
/// confirmed airborne window that loses tracking for too long is marked
/// insufficientData rather than trusted.
///
/// Takeoff requires both ankles to show a sustained, windowed upward rise
/// (never a single-frame threshold), persisting continuously for a short
/// debounce. Landing requires each ankle, independently, to hold near its
/// own calibrated baseline continuously for that same short debounce - the
/// two feet are not required to satisfy this on the same frame or even
/// overlap in time, since a real landing lets one foot settle slightly
/// before the other. Landing is confirmed once both feet have each
/// individually demonstrated their own sustained settle. All of this uses
/// raw per-frame landmark positions, never an EMA - smoothing lags too much
/// for a fast transition.
///
/// Height is calibrated hip displacement (standing hip baseline minus the
/// retrospective apex), converted with the existing height/scale
/// infrastructure - not flight-time physics, since the current camera/ML
/// Kit pipeline exposes no reliable capture timestamp for a Pose frame.
///
/// Re-arming after a confirmed attempt uses an independent fresh stability
/// window: is the athlete currently holding still, wherever that is - never
/// "are they within X% of their exact pre-jump pixel position." The
/// original calibration baseline is never touched again after calibration.
class VerticalJumpEngine extends ExerciseEngine {
  VerticalJumpEngine({required this.userHeightCm});

  final double userHeightCm;

  static const int kMaxAttempts = 3;

  static const String _setupInstruction =
      'Stand inside the marked area, facing the camera, with your entire '
      'body visible from head to feet. Hold still to calibrate, then '
      'perform up to $kMaxAttempts maximum-effort vertical jumps, one at a '
      'time. No running or stepping approach - jump straight up and stay '
      'roughly in the marked area.';

  /// How long a standing position must hold, both for the initial
  /// calibration and (against a fresh, independent reference - never the
  /// calibration baseline) when re-confirming a stable stance after an
  /// attempt.
  static const Duration _kStabilityWindow = Duration(milliseconds: 1300);

  /// Number of recent raw samples retained per foot for the windowed-rise
  /// computation used by takeoff detection. Small and fixed, mirroring the
  /// bounded trailing-sample-window pattern already used elsewhere in this
  /// codebase for event detection - not an independent tunable threshold.
  static const int _kAnkleWindowSize = 4;

  /// How long a single foot's tracking may lapse before its rise window is
  /// discarded as stale, so a fresh sample is never compared against an
  /// old one across a real tracking gap (which would fabricate a "rise").
  /// The smallest bound that comfortably survives an isolated missed frame.
  static const Duration _kMaxAnkleGapDuration = Duration(milliseconds: 250);

  /// Ankle rise within its windowed-rise sample, as a fraction of body
  /// scale, required (on both feet) as takeoff evidence - the primary
  /// signal, since a foot actually leaving the ground is what distinguishes
  /// a jump from a deep knee bend. Feet decide the event; the hip is never
  /// consulted here.
  static const double _kAnkleTakeoffRiseFraction = 0.04;

  /// How long both feet must show sustained rise, continuously, before a
  /// takeoff is confirmed - the temporal debounce that keeps a single noisy
  /// frame from fabricating a takeoff.
  static const Duration _kTakeoffPersistenceDuration = Duration(milliseconds: 150);

  /// How close each foot must return to its own calibrated ground baseline
  /// to count as landed. Sized for natural post-jump ankle-position
  /// variation, not exact pixel recovery: physical diagnostic testing
  /// showed a healthy landing's per-foot baseline error settling around
  /// 19.5-32.4 px (roughly 9-15% of a ~222.5 px calibrated body scale) even
  /// with fully healthy tracking (21/21 samples, 0 gaps) - well beyond the
  /// previous 4% (~8.9 px in that same test), which meant landing was never
  /// confirmed and every attempt fell through to the 2500 ms safety-net
  /// timeout instead.
  static const double _kAnkleLandingToleranceFraction = 0.15;

  /// How long both feet must stay near their ground baseline, continuously,
  /// before a landing is confirmed - so a single noisy near-baseline frame
  /// mid-flight can't end the attempt early.
  static const Duration _kLandingDebounce = Duration(milliseconds: 180);

  /// Safety net from a confirmed takeoff: real human airborne time plus
  /// landing debounce is well under this, so exceeding it means tracking
  /// was lost during a genuine, already-confirmed jump.
  static const Duration _kMaxAirborneDuration = Duration(milliseconds: 2500);

  /// Consecutive frames with zero usable core-landmark data (during a
  /// confirmed airborne window) tolerated before the attempt is abandoned
  /// as insufficient data. A frame with at least partial data (e.g. hip but
  /// not both ankles) never counts against this - only total loss does.
  static const int _kMaxConsecutiveNotVisibleFrames = 10;

  /// Maximum horizontal hip drift from the calibrated baseline, measured
  /// only across a confirmed airborne window, tolerated before that jump is
  /// flagged invalid. A validity gate, not a perspective correction, and
  /// never a factor in whether an attempt started.
  static const double _kHorizontalDriftToleranceFraction = 0.25;

  /// How far the hip-to-ankle vertical span (see [_bodyScalePx]) may
  /// collapse below its calibrated standing value, as a fraction of
  /// [_bodyScalePx], during a confirmed airborne window before the attempt
  /// is flagged [JumpInvalidReason.legConfigurationChange] instead of being
  /// scored. A validity gate only - never consulted for takeoff/landing
  /// events or the height formula itself.
  ///
  /// V1 PLACEHOLDER - not physically validated yet. Chosen conservatively
  /// (comfortably above expected natural knee-flexion collapse, comfortably
  /// below the collapse implied by the ~23-24cm vs ~59-60cm tuck-jump
  /// exploit observed in testing) but must be tuned against real recordings
  /// of natural jumps vs. deliberate tucks before being trusted.
  static const double _kLegSpanCollapseToleranceFraction = 0.30;

  /// How much hip/ankle sway is tolerated around a freshly self-established
  /// re-arm anchor (see [_processAwaitingBaseline]) before it's considered
  /// still settling. This is a materially different concept from a
  /// calibration-distance check: it measures ongoing micro-sway around
  /// wherever the athlete currently happens to be standing, not distance
  /// from their original pre-jump position, so it can be - and is - a
  /// tighter fraction than a positional-drift tolerance would need to be.
  static const double _kRearmMovementToleranceFraction = 0.05;

  /// How much hip/ankle positional drift is tolerated during calibration,
  /// normalized by a live per-frame body-scale estimate, before it counts
  /// as the athlete genuinely repositioning (stepping, adjusting stance,
  /// changing distance) rather than ordinary ML Kit landmark jitter.
  /// Deliberately reuses [_kRearmMovementToleranceFraction]'s value rather
  /// than inventing a new one: both answer the same underlying question -
  /// "is the athlete holding a stationary stance" - just at different
  /// lifecycle moments (locking in the measurement reference itself here,
  /// vs. confirming readiness for the next attempt there).
  static const double _kCalibrationPositionToleranceFraction = 0.05;

  /// How many samples on each side of the raw-minimum hip-Y candidate are
  /// pulled into the local window used to confirm the apex (see
  /// [_finalizeAttempt]). A single ML Kit jitter/motion-blur frame that
  /// happens to read as the most extreme sample gets outvoted by its
  /// window neighbors once the median is taken, without requiring a
  /// minimum sample count - with fewer than five airborne samples (short
  /// jumps sample sparsely) the window simply clamps to whatever exists,
  /// down to a single sample, rather than rejecting the attempt.
  static const int _kApexCorroborationRadius = 2;

  _JumpState _state = _JumpState.calibrating;
  bool _isBodyVisible = false;

  // Calibration - a one-time reference snapshot. Never repeated, and never
  // becomes an ongoing per-frame gate once it hands off fixed references.
  DateTime? _stableSince;
  final List<double> _calHipY = [];
  final List<double> _calHipX = [];
  final List<double> _calLeftAnkleY = [];
  final List<double> _calRightAnkleY = [];
  // Nose-to-ankle standing-height samples, collected from the same frames
  // as the lists above so the scale reference describes the athlete's same
  // stable stance as the baseline - never locked in from an early,
  // possibly-unstable frame. Invalid/non-positive readings are rejected at
  // collection time (see _processCalibration), not filtered out later.
  final List<double> _calStandingHeightPx = [];
  double? _cmPerPixel;

  // Positional-stability reference for the current calibration window: set
  // from the first frame of the window, checked against every later frame
  // in the same window. A violation discards the window (see
  // _resetCalibrationWindow) rather than letting a moving athlete lock in.
  double? _calReferenceHipY;
  double? _calReferenceLeftAnkleY;
  double? _calReferenceRightAnkleY;

  double? _baselineHipY;
  double? _baselineHipX;
  double? _baselineLeftAnkleY;
  double? _baselineRightAnkleY;

  // --- TEMPORARY DIAGNOSTIC INSTRUMENTATION ---
  // Raw calibrated hip-to-ankle pixel span, stored purely for diagnostic
  // exposure (the derived *Px thresholds below are what real logic uses -
  // this raw value isn't otherwise needed once they're computed).
  double _bodyScalePx = 0;
  // --- END TEMPORARY DIAGNOSTIC INSTRUMENTATION ---

  // Thresholds resolved once, from the athlete's calibrated body scale.
  double _ankleTakeoffRisePx = 0;
  double _ankleLandingTolerancePx = 0;
  double _driftTolerancePx = 0;
  double _rearmMovementTolerancePx = 0;
  double _legSpanCollapseTolerancePx = 0;

  // Takeoff evidence while READY - per-foot bounded windows, independent of
  // each other so a brief single-foot dropout doesn't corrupt the other's
  // evidence.
  final _AnkleTracker _leftAnkle = _AnkleTracker();
  final _AnkleTracker _rightAnkle = _AnkleTracker();
  DateTime? _takeoffCandidateSince;

  // Confirmed airborne window.
  DateTime? _takeoffTime;
  final List<double> _airborneHipYSamples = [];
  double _maxAbsHipXDriftPx = 0;
  double _maxLegSpanCollapsePx = 0;
  int _consecutiveNotVisible = 0;

  // Landing evidence, tracked independently per foot: each foot gets its
  // own continuous-debounce streak against its own baseline, and once a
  // foot's streak reaches _kLandingDebounce it latches settled (and stays
  // settled even if that foot drifts briefly afterward - the sustained
  // evidence already collected is trustworthy). Landing is confirmed the
  // moment both latches are true, however far apart in time they each
  // individually settled.
  DateTime? _leftLandingCandidateSince;
  DateTime? _rightLandingCandidateSince;
  bool _leftSettled = false;
  bool _rightSettled = false;

  // --- TEMPORARY DIAGNOSTIC INSTRUMENTATION ---
  // Read-only counters over the confirmed airborne window, printed once at
  // attempt finalization and never consulted by any detection/measurement
  // logic. Intended to be removed once real runtime data has been
  // collected to explain why _airborneHipYSamples is coming back empty.
  int _diagFramesTotal = 0;
  int _diagHipSamples = 0;
  int _diagLeftAnkleSamples = 0;
  int _diagRightAnkleSamples = 0;
  int _diagNullPoseFrames = 0;
  int _diagHipConfidenceInsufficientFrames = 0;
  int _diagHipOtherNullReasonFrames = 0;
  // --- END TEMPORARY DIAGNOSTIC INSTRUMENTATION ---

  // --- TEMPORARY LANDING DIAGNOSTIC INSTRUMENTATION ---
  // Read-only observation of the same per-foot values the real landing
  // check now computes, plus derived streak bookkeeping the real check
  // doesn't keep (it only tracks the CURRENT unbroken per-foot streak,
  // nulling it on every break until it latches settled - these separately
  // track the longest streak ever seen and a combined "both landed at
  // once" streak, neither of which the real logic needs). Never read by
  // any detection/measurement logic.
  double? _diagMinAbsLeftDelta;
  double? _diagMinAbsRightDelta;
  double? _diagLastLeftDelta;
  double? _diagLastRightDelta;
  // Raw (not delta) ankle-Y values, exposed alongside the baselines so the
  // two can be visually compared directly rather than only through the
  // computed delta.
  double? _diagLastLeftY;
  double? _diagLastRightY;
  double? _diagMinAbsLeftDeltaY;
  double? _diagMinAbsRightDeltaY;
  bool _diagLeftEverLanded = false;
  bool _diagRightEverLanded = false;
  DateTime? _diagLeftLandedStreakSince;
  DateTime? _diagRightLandedStreakSince;
  DateTime? _diagBothLandedStreakSince;
  Duration _diagLongestLeftLandedStreak = Duration.zero;
  Duration _diagLongestRightLandedStreak = Duration.zero;
  Duration _diagLongestBothLandedStreak = Duration.zero;
  // --- END TEMPORARY LANDING DIAGNOSTIC INSTRUMENTATION ---

  // Re-arm: an independent fresh stability window, anchored to wherever the
  // athlete currently is - never the original calibration baseline.
  DateTime? _rearmStableSince;
  double? _rearmReferenceHipY;
  double? _rearmReferenceLeftAnkleY;
  double? _rearmReferenceRightAnkleY;

  final List<JumpAttemptResult> _attempts = [];

  List<JumpAttemptResult> get attempts => List.unmodifiable(_attempts);

  // --- Read-only accessors for lib/audio/exercise_voice_coach.dart -----
  // Expose already-computed state for voice coaching; no effect on any
  // calculation/detection/scoring above.

  /// Whether the athlete is calibrated and the engine is currently waiting
  /// for the next jump (the "Ready - Jump N/kMaxAttempts" status).
  bool get isReadyToJump => _state == _JumpState.ready;

  /// Whether all attempts are done and the test has naturally completed.
  bool get isTestComplete => _state == _JumpState.testComplete;

  double? get bestValidHeightCm {
    double? best;
    for (final attempt in _attempts) {
      final height = attempt.heightCm;
      if (attempt.isValid && height != null && (best == null || height > best)) {
        best = height;
      }
    }
    return best;
  }

  @override
  double? get groundGuideImageY {
    final left = _baselineLeftAnkleY;
    final right = _baselineRightAnkleY;
    if (left == null || right == null) return null;
    return (left + right) / 2;
  }

  /// Purely a rendering hint for [LiveTestScreen] to show a static "stand
  /// here" position guide - only meaningful during initial setup, before
  /// calibration has locked in.
  @override
  bool get showPositionGuide => _state == _JumpState.calibrating;

  // --- TEMPORARY DIAGNOSTIC INSTRUMENTATION ---
  String? _lastDiagnosticText;

  @override
  String? get diagnosticText => _lastDiagnosticText;
  // --- END TEMPORARY DIAGNOSTIC INSTRUMENTATION ---

  @override
  void reset() {
    _state = _JumpState.calibrating;
    _isBodyVisible = false;
    _resetCalibrationWindow();
    _cmPerPixel = null;
    _baselineHipY = null;
    _baselineHipX = null;
    _baselineLeftAnkleY = null;
    _baselineRightAnkleY = null;
    _bodyScalePx = 0;
    _ankleTakeoffRisePx = 0;
    _ankleLandingTolerancePx = 0;
    _driftTolerancePx = 0;
    _rearmMovementTolerancePx = 0;
    _legSpanCollapseTolerancePx = 0;
    _rearmStableSince = null;
    _rearmReferenceHipY = null;
    _rearmReferenceLeftAnkleY = null;
    _rearmReferenceRightAnkleY = null;
    _attempts.clear();
    _lastDiagnosticText = null;
    _resetAttemptState();
  }

  void _resetAttemptState() {
    _leftAnkle.reset();
    _rightAnkle.reset();
    _takeoffCandidateSince = null;
    _takeoffTime = null;
    _airborneHipYSamples.clear();
    _maxAbsHipXDriftPx = 0;
    _maxLegSpanCollapsePx = 0;
    _leftLandingCandidateSince = null;
    _rightLandingCandidateSince = null;
    _leftSettled = false;
    _rightSettled = false;
    _consecutiveNotVisible = 0;
    _resetDiagnostics();
  }

  // --- TEMPORARY DIAGNOSTIC INSTRUMENTATION ---
  void _resetDiagnostics() {
    _diagFramesTotal = 0;
    _diagHipSamples = 0;
    _diagLeftAnkleSamples = 0;
    _diagRightAnkleSamples = 0;
    _diagNullPoseFrames = 0;
    _diagHipConfidenceInsufficientFrames = 0;
    _diagHipOtherNullReasonFrames = 0;
    _diagMinAbsLeftDelta = null;
    _diagMinAbsRightDelta = null;
    _diagLastLeftDelta = null;
    _diagLastRightDelta = null;
    _diagLastLeftY = null;
    _diagLastRightY = null;
    _diagMinAbsLeftDeltaY = null;
    _diagMinAbsRightDeltaY = null;
    _diagLeftEverLanded = false;
    _diagRightEverLanded = false;
    _diagLeftLandedStreakSince = null;
    _diagRightLandedStreakSince = null;
    _diagBothLandedStreakSince = null;
    _diagLongestLeftLandedStreak = Duration.zero;
    _diagLongestRightLandedStreak = Duration.zero;
    _diagLongestBothLandedStreak = Duration.zero;
  }
  // --- END TEMPORARY DIAGNOSTIC INSTRUMENTATION ---

  double _average(List<double> values) => values.reduce((a, b) => a + b) / values.length;

  @override
  void processPose(Pose? pose) {
    if (_state == _JumpState.testComplete) return;

    final now = DateTime.now();

    switch (_state) {
      case _JumpState.calibrating:
        _processCalibration(pose, now);
      case _JumpState.awaitingBaseline:
        _processAwaitingBaseline(pose, now);
      case _JumpState.ready:
        _processReady(pose, now);
      case _JumpState.airborne:
        _processAirborne(pose, now);
      case _JumpState.testComplete:
        break;
    }
  }

  /// One-time setup snapshot. Requires the existing full-body visibility
  /// check (a coarse "are they properly framed" gate, not a per-landmark
  /// jump-algorithm requirement), positional stability (the athlete must
  /// actually be holding still, not just confidently detected while still
  /// stepping into place), and the existing nose-to-ankle scale
  /// infrastructure. Once locked in, this state is never revisited and its
  /// references never re-validated.
  void _processCalibration(Pose? pose, DateTime now) {
    final visible = pose != null && isFullBodyVisible(pose);
    _isBodyVisible = visible;

    if (!visible) {
      _resetCalibrationWindow();
      return;
    }

    // isFullBodyVisible already guarantees both hips and both ankles are
    // individually visible at the same confidence threshold these use.
    final hipY = averageHipY(pose)!;
    final hipX = averageHipX(pose)!;
    final leftY = leftAnkleY(pose)!;
    final rightY = rightAnkleY(pose)!;

    if (_calReferenceHipY == null) {
      // First frame of a fresh window - it becomes the reference every
      // later frame in this same window is checked against.
      _calReferenceHipY = hipY;
      _calReferenceLeftAnkleY = leftY;
      _calReferenceRightAnkleY = rightY;
    } else {
      // A live per-frame body-scale estimate normalizes the drift check so
      // it holds regardless of camera distance - the same normalization
      // idea used everywhere else in this engine, just computed live here
      // since the real calibrated bodyScalePx doesn't exist yet. A single
      // frame with degenerate geometry (frameBodyScale <= 0) is treated as
      // inconclusive noise, not a movement violation.
      final frameBodyScale = ((leftY + rightY) / 2) - hipY;
      if (frameBodyScale > 0) {
        final tolerancePx = frameBodyScale * _kCalibrationPositionToleranceFraction;
        final hipDrift = (hipY - _calReferenceHipY!).abs();
        final leftDrift = (leftY - _calReferenceLeftAnkleY!).abs();
        final rightDrift = (rightY - _calReferenceRightAnkleY!).abs();
        if (hipDrift > tolerancePx || leftDrift > tolerancePx || rightDrift > tolerancePx) {
          // Genuine repositioning, not ML Kit jitter - the in-progress
          // window no longer represents one continuous stable stance.
          // Discard it and start a fresh window anchored to this frame.
          _resetCalibrationWindow();
          _calReferenceHipY = hipY;
          _calReferenceLeftAnkleY = leftY;
          _calReferenceRightAnkleY = rightY;
        }
      }
    }

    _stableSince ??= now;
    _calHipY.add(hipY);
    _calHipX.add(hipX);
    _calLeftAnkleY.add(leftY);
    _calRightAnkleY.add(rightY);
    // Collected from the same frames as the position samples above, so the
    // scale reference describes the same stable stance as the baseline -
    // never a separately-timed, possibly-unstable frame. Invalid/
    // non-positive readings are rejected here rather than being averaged
    // in.
    final standingHeightPx = estimateStandingHeightPixels(pose);
    if (standingHeightPx != null && standingHeightPx > 0) {
      _calStandingHeightPx.add(standingHeightPx);
    }

    if (now.difference(_stableSince!) < _kStabilityWindow) {
      return;
    }

    final avgHipY = _average(_calHipY);
    final avgHipX = _average(_calHipX);
    final avgLeftAnkleY = _average(_calLeftAnkleY);
    final avgRightAnkleY = _average(_calRightAnkleY);
    final bodyScalePx = ((avgLeftAnkleY + avgRightAnkleY) / 2) - avgHipY;

    if (bodyScalePx <= 0) {
      // Degenerate geometry (ankles above hip) - shouldn't happen standing
      // upright. Keep collecting rather than locking in a broken scale.
      _resetCalibrationWindow();
      return;
    }

    // Representative standing-height pixel value for this same stable
    // window, using the median (more robust to a single stray reading than
    // the mean) - computed, and cmPerPixel derived from it, only now that
    // the window has actually finalized. A window with no valid reading at
    // all is treated the same as degenerate geometry: discarded rather
    // than locked in without a usable scale.
    final representativeHeightPx = _median(_calStandingHeightPx);
    final cmPerPixelValue =
        representativeHeightPx != null ? cmPerPixel(representativeHeightPx, userHeightCm) : null;
    if (cmPerPixelValue == null) {
      _resetCalibrationWindow();
      return;
    }

    _baselineHipY = avgHipY;
    _baselineHipX = avgHipX;
    _baselineLeftAnkleY = avgLeftAnkleY;
    _baselineRightAnkleY = avgRightAnkleY;
    _bodyScalePx = bodyScalePx;
    _cmPerPixel = cmPerPixelValue;
    _ankleTakeoffRisePx = bodyScalePx * _kAnkleTakeoffRiseFraction;
    _ankleLandingTolerancePx = bodyScalePx * _kAnkleLandingToleranceFraction;
    _driftTolerancePx = bodyScalePx * _kHorizontalDriftToleranceFraction;
    _rearmMovementTolerancePx = bodyScalePx * _kRearmMovementToleranceFraction;
    _legSpanCollapseTolerancePx = bodyScalePx * _kLegSpanCollapseToleranceFraction;
    // Calibration hands off fixed references and gets out of the way - it
    // never re-checks "is the athlete still standing like this" again.
    _state = _JumpState.ready;
  }

  /// Middle value of [values] (average of the two middle values for an
  /// even-sized list), or null if empty. More robust to a single stray
  /// reading than the arithmetic mean.
  double? _median(List<double> values) {
    if (values.isEmpty) return null;
    final sorted = [...values]..sort();
    final mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[mid];
    return (sorted[mid - 1] + sorted[mid]) / 2;
  }

  /// Retrospective apex: rather than trusting the single most extreme raw
  /// sample outright, finds its index and takes the median of a small
  /// temporal window (up to [_kApexCorroborationRadius] samples on each
  /// side, clamped to the list's bounds) around it. A lone jitter/motion-
  /// blur outlier gets outvoted by its neighbors once the median is taken.
  /// No minimum sample count is required - with few airborne samples
  /// (short jumps sample sparsely) the window simply clamps to whatever
  /// exists, down to a single sample, which trivially returns itself.
  double _robustApexHipY(List<double> samples) {
    var minIndex = 0;
    for (var i = 1; i < samples.length; i++) {
      if (samples[i] < samples[minIndex]) minIndex = i;
    }
    final windowStart = (minIndex - _kApexCorroborationRadius).clamp(0, samples.length - 1);
    final windowEnd = (minIndex + _kApexCorroborationRadius).clamp(0, samples.length - 1);
    return _median(samples.sublist(windowStart, windowEnd + 1))!;
  }

  /// Discards the in-progress calibration accumulation window: the sample
  /// lists (hip/ankle position AND standing-height), the stability timer,
  /// and the positional-stability reference. [_cmPerPixel] is never set
  /// until a window successfully finalizes (see [_processCalibration]), so
  /// there is nothing stale to discard there - a failed window simply never
  /// produced a value in the first place.
  void _resetCalibrationWindow() {
    _stableSince = null;
    _calHipY.clear();
    _calHipX.clear();
    _calLeftAnkleY.clear();
    _calRightAnkleY.clear();
    _calStandingHeightPx.clear();
    _calReferenceHipY = null;
    _calReferenceLeftAnkleY = null;
    _calReferenceRightAnkleY = null;
  }

  /// Continuous observation. There is no "attempt started" event: this only
  /// ever looks for ankle-based takeoff evidence, and resets silently - no
  /// state change, no bookkeeping kept - whenever that evidence isn't
  /// present. Standing still, swaying, translating toward/away from the
  /// camera, or a full squat-and-recover all fall through here indefinitely
  /// without consequence, because the hip is never consulted for this
  /// decision - only sustained, windowed rise on BOTH feet counts.
  void _processReady(Pose? pose, DateTime now) {
    final leftY = pose != null ? leftAnkleY(pose) : null;
    final rightY = pose != null ? rightAnkleY(pose) : null;
    final hipY = pose != null ? averageHipY(pose) : null;
    _isBodyVisible = leftY != null || rightY != null || hipY != null;

    _leftAnkle.push(leftY, now, maxGap: _kMaxAnkleGapDuration, windowSize: _kAnkleWindowSize);
    _rightAnkle.push(rightY, now, maxGap: _kMaxAnkleGapDuration, windowSize: _kAnkleWindowSize);

    final leftRise = _leftAnkle.rise;
    final rightRise = _rightAnkle.rise;
    final bothRising = leftRise != null &&
        rightRise != null &&
        leftRise >= _ankleTakeoffRisePx &&
        rightRise >= _ankleTakeoffRisePx;

    if (!bothRising) {
      _takeoffCandidateSince = null;
      return;
    }

    _takeoffCandidateSince ??= now;
    if (now.difference(_takeoffCandidateSince!) >= _kTakeoffPersistenceDuration) {
      _state = _JumpState.airborne;
      _takeoffTime = _takeoffCandidateSince;
      _leftAnkle.reset();
      _rightAnkle.reset();
      _airborneHipYSamples.clear();
      _maxAbsHipXDriftPx = 0;
      _maxLegSpanCollapsePx = 0;
      _consecutiveNotVisible = 0;
      _resetDiagnostics();
    }
  }

  /// A genuine ankle-based takeoff is already confirmed. From here: the hip
  /// is tracked only for retrospective height/drift measurement, never for
  /// event decisions, and landing is decided purely from both ankles
  /// returning to their own calibrated ground baseline.
  void _processAirborne(Pose? pose, DateTime now) {
    final hipY = pose != null ? averageHipY(pose) : null;
    final hipX = pose != null ? averageHipX(pose) : null;
    final leftY = pose != null ? leftAnkleY(pose) : null;
    final rightY = pose != null ? rightAnkleY(pose) : null;
    final avgAnkleY = pose != null ? averageAnkleY(pose) : null;

    // --- TEMPORARY DIAGNOSTIC INSTRUMENTATION ---
    // Read-only counters - does not influence any detection/measurement
    // decision below.
    _diagFramesTotal++;
    if (pose == null) {
      _diagNullPoseFrames++;
    } else if (hipY == null) {
      final leftHipLandmark = pose.landmarks[PoseLandmarkType.leftHip];
      final rightHipLandmark = pose.landmarks[PoseLandmarkType.rightHip];
      final leftHipConfident = isLandmarkVisible(leftHipLandmark);
      final rightHipConfident = isLandmarkVisible(rightHipLandmark);
      if (!leftHipConfident && !rightHipConfident) {
        // Case B: pose present, but both hip landmarks below the
        // confidence threshold.
        _diagHipConfidenceInsufficientFrames++;
      } else {
        // Case C: averageHipY() returned null for some other reason
        // (shouldn't occur given its implementation, logged defensively).
        _diagHipOtherNullReasonFrames++;
      }
    }
    if (hipY != null) _diagHipSamples++;
    if (leftY != null) _diagLeftAnkleSamples++;
    if (rightY != null) _diagRightAnkleSamples++;
    // --- END TEMPORARY DIAGNOSTIC INSTRUMENTATION ---

    final anySignal = hipY != null || leftY != null || rightY != null;
    _isBodyVisible = anySignal;
    if (anySignal) {
      _consecutiveNotVisible = 0;
    } else {
      _consecutiveNotVisible++;
      if (_consecutiveNotVisible > _kMaxConsecutiveNotVisibleFrames) {
        _finalizeAttempt(forcedReason: JumpInvalidReason.insufficientData);
        return;
      }
    }

    // Measurement trajectory: only ever append a real sample. A gap is
    // never duplicated or interpolated - it's simply absent this frame.
    if (hipY != null) _airborneHipYSamples.add(hipY);
    if (hipX != null) _trackDrift(hipX);
    if (hipY != null && avgAnkleY != null) _trackLegConfiguration(hipY, avgAnkleY);

    // Each foot is evaluated independently against its own baseline and its
    // own debounce streak - the two feet are not required to be inside
    // tolerance on the same frame, or even overlap in time, since a real
    // landing routinely has one foot settle a little before the other.
    // Once a foot's own streak reaches _kLandingDebounce it latches settled
    // and stays settled for the rest of this attempt.
    if (!_leftSettled && leftY != null) {
      final leftLanded = (_baselineLeftAnkleY! - leftY) <= _ankleLandingTolerancePx;
      if (leftLanded) {
        _leftLandingCandidateSince ??= now;
        if (now.difference(_leftLandingCandidateSince!) >= _kLandingDebounce) {
          _leftSettled = true;
        }
      } else {
        _leftLandingCandidateSince = null;
      }
    }
    if (!_rightSettled && rightY != null) {
      final rightLanded = (_baselineRightAnkleY! - rightY) <= _ankleLandingTolerancePx;
      if (rightLanded) {
        _rightLandingCandidateSince ??= now;
        if (now.difference(_rightLandingCandidateSince!) >= _kLandingDebounce) {
          _rightSettled = true;
        }
      } else {
        _rightLandingCandidateSince = null;
      }
    }
    if (_leftSettled && _rightSettled) {
      _finalizeAttempt();
      return;
    }
    // If a foot is unavailable this frame, its own streak is simply left
    // untouched rather than reset, so a single-frame gap on either foot
    // mid-debounce can't force it to restart.

    // --- TEMPORARY LANDING DIAGNOSTIC INSTRUMENTATION ---
    // Read-only observation of the exact same values/formula the real
    // landing check above uses - does not influence it in any way.
    if (leftY != null) {
      final leftDelta = _baselineLeftAnkleY! - leftY;
      _diagLastLeftDelta = leftDelta;
      _diagLastLeftY = leftY;
      final absLeftDelta = leftDelta.abs();
      if (_diagMinAbsLeftDelta == null || absLeftDelta < _diagMinAbsLeftDelta!) {
        _diagMinAbsLeftDelta = absLeftDelta;
        _diagMinAbsLeftDeltaY = leftY;
      }
      if (leftDelta <= _ankleLandingTolerancePx) {
        _diagLeftEverLanded = true;
        _diagLeftLandedStreakSince ??= now;
        final streak = now.difference(_diagLeftLandedStreakSince!);
        if (streak > _diagLongestLeftLandedStreak) _diagLongestLeftLandedStreak = streak;
      } else {
        _diagLeftLandedStreakSince = null;
      }
    }
    if (rightY != null) {
      final rightDelta = _baselineRightAnkleY! - rightY;
      _diagLastRightDelta = rightDelta;
      _diagLastRightY = rightY;
      final absRightDelta = rightDelta.abs();
      if (_diagMinAbsRightDelta == null || absRightDelta < _diagMinAbsRightDelta!) {
        _diagMinAbsRightDelta = absRightDelta;
        _diagMinAbsRightDeltaY = rightY;
      }
      if (rightDelta <= _ankleLandingTolerancePx) {
        _diagRightEverLanded = true;
        _diagRightLandedStreakSince ??= now;
        final streak = now.difference(_diagRightLandedStreakSince!);
        if (streak > _diagLongestRightLandedStreak) _diagLongestRightLandedStreak = streak;
      } else {
        _diagRightLandedStreakSince = null;
      }
    }
    if (leftY != null && rightY != null) {
      final bothLandedNow = (_baselineLeftAnkleY! - leftY) <= _ankleLandingTolerancePx &&
          (_baselineRightAnkleY! - rightY) <= _ankleLandingTolerancePx;
      if (bothLandedNow) {
        _diagBothLandedStreakSince ??= now;
        final streak = now.difference(_diagBothLandedStreakSince!);
        if (streak > _diagLongestBothLandedStreak) _diagLongestBothLandedStreak = streak;
      } else {
        _diagBothLandedStreakSince = null;
      }
    }
    final diagLeftDebounceMs = _leftLandingCandidateSince != null
        ? now.difference(_leftLandingCandidateSince!).inMilliseconds
        : null;
    final diagRightDebounceMs = _rightLandingCandidateSince != null
        ? now.difference(_rightLandingCandidateSince!).inMilliseconds
        : null;
    debugPrint(
      'LANDING_DIAG: '
      't=${now.difference(_takeoffTime!).inMilliseconds} '
      'Ldelta=${leftY != null ? (_baselineLeftAnkleY! - leftY).toStringAsFixed(1) : "null"} '
      'Rdelta=${rightY != null ? (_baselineRightAnkleY! - rightY).toStringAsFixed(1) : "null"} '
      'tol=${_ankleLandingTolerancePx.toStringAsFixed(1)} '
      'L=${leftY != null ? ((_baselineLeftAnkleY! - leftY) <= _ankleLandingTolerancePx) : "n/a"} '
      'R=${rightY != null ? ((_baselineRightAnkleY! - rightY) <= _ankleLandingTolerancePx) : "n/a"} '
      'leftSettled=$_leftSettled '
      'rightSettled=$_rightSettled '
      'debounceL=${diagLeftDebounceMs ?? "-"} '
      'debounceR=${diagRightDebounceMs ?? "-"}',
    );
    // --- END TEMPORARY LANDING DIAGNOSTIC INSTRUMENTATION ---

    if (now.difference(_takeoffTime!) > _kMaxAirborneDuration) {
      _finalizeAttempt(forcedReason: JumpInvalidReason.insufficientData);
    }
  }

  void _trackDrift(double hipX) {
    final drift = (hipX - _baselineHipX!).abs();
    if (drift > _maxAbsHipXDriftPx) _maxAbsHipXDriftPx = drift;
  }

  /// Tracks how far the hip-to-ankle vertical span has collapsed below its
  /// calibrated standing value ([_bodyScalePx]) at any point in the
  /// confirmed airborne window - the signature of a deliberate leg tuck.
  /// Mirrors [_trackDrift]'s running-max pattern; evaluated once at
  /// [_finalizeAttempt], never influences takeoff/landing or the height
  /// formula itself.
  void _trackLegConfiguration(double hipY, double avgAnkleY) {
    final legSpanPx = avgAnkleY - hipY;
    final collapsePx = _bodyScalePx - legSpanPx;
    if (collapsePx > _maxLegSpanCollapsePx) _maxLegSpanCollapsePx = collapsePx;
  }

  /// Only ever called from [_JumpState.airborne] - by definition, a genuine
  /// airborne event has already happened, so this always consumes one of
  /// the three attempts. The only open question is whether it's valid.
  void _finalizeAttempt({JumpInvalidReason? forcedReason}) {
    final attemptNumber = _attempts.length + 1;
    final JumpAttemptResult result;

    if (forcedReason != null) {
      result = JumpAttemptResult(
        attemptNumber: attemptNumber,
        isValid: false,
        invalidReason: forcedReason,
      );
    } else if (_airborneHipYSamples.isEmpty) {
      // Both feet behaved like a genuine jump, but the hip was never once
      // usable during the window - nothing to measure from.
      result = JumpAttemptResult(
        attemptNumber: attemptNumber,
        isValid: false,
        invalidReason: JumpInvalidReason.insufficientData,
      );
    } else if (_maxAbsHipXDriftPx > _driftTolerancePx) {
      result = JumpAttemptResult(
        attemptNumber: attemptNumber,
        isValid: false,
        invalidReason: JumpInvalidReason.excessiveDrift,
      );
    } else if (_maxLegSpanCollapsePx > _legSpanCollapseTolerancePx) {
      result = JumpAttemptResult(
        attemptNumber: attemptNumber,
        isValid: false,
        invalidReason: JumpInvalidReason.legConfigurationChange,
      );
    } else {
      // Retrospective apex: a locally-corroborated extreme (see
      // _robustApexHipY) rather than a bare single-sample minimum, found
      // only now that the confirmed airborne window is closed - never
      // chased causally frame-by-frame.
      final apexHipY = _robustApexHipY(_airborneHipYSamples);
      final heightPx = _baselineHipY! - apexHipY;
      final heightCm = heightPx * _cmPerPixel!;
      result = JumpAttemptResult(attemptNumber: attemptNumber, isValid: true, heightCm: heightCm);
    }

    // --- TEMPORARY DIAGNOSTIC INSTRUMENTATION ---
    // One line per finalized attempt, printed before counters are reset.
    // Read-only - does not influence the result computed above.
    final flightMs = DateTime.now().difference(_takeoffTime!).inMilliseconds;
    debugPrint(
      'VERTICAL_JUMP_DIAGNOSTIC: '
      'attempt=$attemptNumber '
      'flightMs=$flightMs '
      'framesTotal=$_diagFramesTotal '
      'hipSamples=$_diagHipSamples '
      'leftAnkleSamples=$_diagLeftAnkleSamples '
      'rightAnkleSamples=$_diagRightAnkleSamples '
      'nullPoseFrames=$_diagNullPoseFrames '
      'invalidHipFrames=${_diagHipConfidenceInsufficientFrames + _diagHipOtherNullReasonFrames} '
      'hipConfidenceInsufficientFrames=$_diagHipConfidenceInsufficientFrames '
      'hipOtherNullReasonFrames=$_diagHipOtherNullReasonFrames '
      'storedHipSamples=${_airborneHipYSamples.length}',
    );
    // --- END TEMPORARY DIAGNOSTIC INSTRUMENTATION ---

    // --- TEMPORARY LANDING DIAGNOSTIC INSTRUMENTATION ---
    // One summary line per finalized attempt, printed before counters are
    // reset. Read-only - does not influence the result computed above.
    debugPrint(
      'LANDING_DIAG_SUMMARY: '
      'attempt=$attemptNumber '
      'baselineLeftAnkleY=${_baselineLeftAnkleY?.toStringAsFixed(1) ?? "n/a"} '
      'baselineRightAnkleY=${_baselineRightAnkleY?.toStringAsFixed(1) ?? "n/a"} '
      'bodyScalePx=${_bodyScalePx.toStringAsFixed(1)} '
      'landingTolerancePx=${_ankleLandingTolerancePx.toStringAsFixed(1)} '
      'lastLeftAnkleY=${_diagLastLeftY?.toStringAsFixed(1) ?? "n/a"} '
      'lastRightAnkleY=${_diagLastRightY?.toStringAsFixed(1) ?? "n/a"} '
      'minAbsLeftAnkleY=${_diagMinAbsLeftDeltaY?.toStringAsFixed(1) ?? "n/a"} '
      'minAbsRightAnkleY=${_diagMinAbsRightDeltaY?.toStringAsFixed(1) ?? "n/a"} '
      'minAbsLdelta=${_diagMinAbsLeftDelta?.toStringAsFixed(1) ?? "n/a"} '
      'minAbsRdelta=${_diagMinAbsRightDelta?.toStringAsFixed(1) ?? "n/a"} '
      'lastLdelta=${_diagLastLeftDelta?.toStringAsFixed(1) ?? "n/a"} '
      'lastRdelta=${_diagLastRightDelta?.toStringAsFixed(1) ?? "n/a"} '
      'leftEverLanded=$_diagLeftEverLanded '
      'rightEverLanded=$_diagRightEverLanded '
      'longestLeftMs=${_diagLongestLeftLandedStreak.inMilliseconds} '
      'longestRightMs=${_diagLongestRightLandedStreak.inMilliseconds} '
      'longestBothMs=${_diagLongestBothLandedStreak.inMilliseconds}',
    );
    // --- END TEMPORARY LANDING DIAGNOSTIC INSTRUMENTATION ---

    _lastDiagnosticText =
        'VERTICAL_JUMP_DIAGNOSTIC\n'
        'Attempt: $attemptNumber\n'
        'Flight: $flightMs ms\n'
        'Frames: $_diagFramesTotal\n'
        'Hip: $_diagHipSamples\n'
        'L ankle: $_diagLeftAnkleSamples\n'
        'R ankle: $_diagRightAnkleSamples\n'
        'Null pose: $_diagNullPoseFrames\n'
        'Hip confidence loss: $_diagHipConfidenceInsufficientFrames\n'
        'Hip other loss: $_diagHipOtherNullReasonFrames\n'
        'Stored hip: ${_airborneHipYSamples.length}\n'
        '--- Landing ---\n'
        'BaseL Y: ${_baselineLeftAnkleY?.toStringAsFixed(1) ?? "n/a"}\n'
        'BaseR Y: ${_baselineRightAnkleY?.toStringAsFixed(1) ?? "n/a"}\n'
        'BodyScalePx: ${_bodyScalePx.toStringAsFixed(1)}\n'
        'Tol: ${_ankleLandingTolerancePx.toStringAsFixed(1)} px\n'
        'Last L Y: ${_diagLastLeftY?.toStringAsFixed(1) ?? "n/a"}\n'
        'Last R Y: ${_diagLastRightY?.toStringAsFixed(1) ?? "n/a"}\n'
        'ClosestL Y: ${_diagMinAbsLeftDeltaY?.toStringAsFixed(1) ?? "n/a"}\n'
        'ClosestR Y: ${_diagMinAbsRightDeltaY?.toStringAsFixed(1) ?? "n/a"}\n'
        'L ever landed: $_diagLeftEverLanded\n'
        'R ever landed: $_diagRightEverLanded\n'
        'Min |Ldelta|: ${_diagMinAbsLeftDelta?.toStringAsFixed(1) ?? "n/a"}\n'
        'Min |Rdelta|: ${_diagMinAbsRightDelta?.toStringAsFixed(1) ?? "n/a"}\n'
        'Last Ldelta: ${_diagLastLeftDelta?.toStringAsFixed(1) ?? "n/a"}\n'
        'Last Rdelta: ${_diagLastRightDelta?.toStringAsFixed(1) ?? "n/a"}\n'
        'Longest L: ${_diagLongestLeftLandedStreak.inMilliseconds}ms\n'
        'Longest R: ${_diagLongestRightLandedStreak.inMilliseconds}ms\n'
        'Longest Both: ${_diagLongestBothLandedStreak.inMilliseconds}ms';

    _attempts.add(result);
    _resetAttemptState();

    if (_attempts.length >= kMaxAttempts) {
      _state = _JumpState.testComplete;
    } else {
      _state = _JumpState.awaitingBaseline;
      _rearmStableSince = null;
      _rearmReferenceHipY = null;
      _rearmReferenceLeftAnkleY = null;
      _rearmReferenceRightAnkleY = null;
    }
  }

  /// Independent fresh stability window - deliberately NOT a comparison
  /// against the original calibration position. The first usable frame
  /// after landing becomes this attempt's own local anchor; the athlete
  /// only needs to hold still relative to wherever they currently are, for
  /// [_kStabilityWindow], before the next attempt is armed. A momentary
  /// tracking loss pauses and re-anchors once tracking resumes - it never
  /// consumes an attempt or ends the test.
  void _processAwaitingBaseline(Pose? pose, DateTime now) {
    final hipY = pose != null ? averageHipY(pose) : null;
    final leftY = pose != null ? leftAnkleY(pose) : null;
    final rightY = pose != null ? rightAnkleY(pose) : null;

    final usable = hipY != null && leftY != null && rightY != null;
    _isBodyVisible = usable;

    if (!usable) {
      _rearmStableSince = null;
      _rearmReferenceHipY = null;
      _rearmReferenceLeftAnkleY = null;
      _rearmReferenceRightAnkleY = null;
      return;
    }

    if (_rearmReferenceHipY == null) {
      _rearmReferenceHipY = hipY;
      _rearmReferenceLeftAnkleY = leftY;
      _rearmReferenceRightAnkleY = rightY;
      _rearmStableSince = now;
      return;
    }

    final stableHip = (hipY - _rearmReferenceHipY!).abs() <= _rearmMovementTolerancePx;
    final stableLeft = (leftY - _rearmReferenceLeftAnkleY!).abs() <= _rearmMovementTolerancePx;
    final stableRight = (rightY - _rearmReferenceRightAnkleY!).abs() <= _rearmMovementTolerancePx;

    if (!stableHip || !stableLeft || !stableRight) {
      // Still settling - re-anchor to the current position and restart the
      // fresh window from here, rather than failing outright.
      _rearmReferenceHipY = hipY;
      _rearmReferenceLeftAnkleY = leftY;
      _rearmReferenceRightAnkleY = rightY;
      _rearmStableSince = now;
      return;
    }

    if (now.difference(_rearmStableSince!) >= _kStabilityWindow) {
      _state = _JumpState.ready;
    }
  }

  String _reasonLabel(JumpInvalidReason reason) => switch (reason) {
    JumpInvalidReason.excessiveDrift => 'excessive horizontal drift',
    JumpInvalidReason.insufficientData => 'insufficient tracking data',
    JumpInvalidReason.legConfigurationChange => 'excessive leg configuration change (tucking)',
  };

  String? _lastAttemptLine() {
    if (_attempts.isEmpty) return null;
    final a = _attempts.last;
    if (a.isValid) {
      return 'Attempt ${a.attemptNumber} complete - Jump height: ${a.heightCm!.toStringAsFixed(1)} cm';
    }
    return 'Attempt ${a.attemptNumber} complete - Invalid (${_reasonLabel(a.invalidReason!)})';
  }

  String _attemptsSummary() {
    return _attempts
        .map((a) {
          if (a.isValid) return 'Attempt ${a.attemptNumber}: ${a.heightCm!.toStringAsFixed(1)} cm';
          return 'Attempt ${a.attemptNumber}: Invalid (${_reasonLabel(a.invalidReason!)})';
        })
        .join('   •   ');
  }

  String _rearmProgressPct() {
    if (_rearmStableSince == null) return '0';
    final elapsedMs = DateTime.now().difference(_rearmStableSince!).inMilliseconds;
    return (elapsedMs / _kStabilityWindow.inMilliseconds * 100).clamp(0, 100).toStringAsFixed(0);
  }

  @override
  ExerciseStatus get status {
    switch (_state) {
      case _JumpState.calibrating:
        if (!_isBodyVisible) {
          return ExerciseStatus(
            primaryText: 'Stand in the marked area and hold still',
            secondaryText: _setupInstruction,
            isBodyVisible: false,
          );
        }
        if (_stableSince == null) {
          return const ExerciseStatus(primaryText: 'Hold still...', isBodyVisible: true);
        }
        final elapsedMs = DateTime.now().difference(_stableSince!).inMilliseconds;
        final pct = (elapsedMs / _kStabilityWindow.inMilliseconds * 100)
            .clamp(0, 100)
            .toStringAsFixed(0);
        return ExerciseStatus(
          primaryText: 'Hold still...',
          secondaryText: 'Calibrating ($pct%)',
          isBodyVisible: true,
        );

      case _JumpState.awaitingBaseline:
        final lastLine = _lastAttemptLine();
        if (!_isBodyVisible) {
          return ExerciseStatus(
            primaryText: 'Step back - keep your full body visible',
            secondaryText: lastLine,
            isBodyVisible: false,
          );
        }
        final progressText = 'Hold still... (${_rearmProgressPct()}%)';
        return ExerciseStatus(
          primaryText: 'Return to the starting area',
          secondaryText: lastLine != null ? '$lastLine   •   $progressText' : progressText,
          isBodyVisible: true,
        );

      case _JumpState.ready:
        return ExerciseStatus(
          primaryText: 'Ready - Jump ${_attempts.length + 1}/$kMaxAttempts',
          secondaryText: 'Jump when ready',
          isBodyVisible: _isBodyVisible,
        );

      case _JumpState.airborne:
        return ExerciseStatus(
          primaryText: 'JUMP!',
          secondaryText: 'Attempt ${_attempts.length + 1}/$kMaxAttempts',
          isBodyVisible: _isBodyVisible,
        );

      case _JumpState.testComplete:
        final best = bestValidHeightCm;
        return ExerciseStatus(
          primaryText: 'Test complete',
          secondaryText: best != null
              ? 'Best jump: ${best.toStringAsFixed(1)} cm   •   ${_attemptsSummary()}'
              : 'No valid jump   •   ${_attemptsSummary()}',
          isBodyVisible: _isBodyVisible,
        );
    }
  }
}
