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

  /// Landmark visibility was lost, or landing evidence never arrived,
  /// during a confirmed airborne event.
  insufficientData,
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

/// Standing vertical jump test: three maximum-effort attempts, scored on the
/// best valid jump height.
///
/// Architecture: there is no real-time "attempt started" event. The engine
/// continuously observes the athlete while [_JumpState.ready], and an
/// attempt only comes into existence retrospectively, once a genuine
/// AIRBORNE -> LANDING event has been confirmed. Standing still, swaying,
/// walking closer/further from the camera, or squatting down and back up
/// without leaving the ground all leave the engine in [_JumpState.ready]
/// forever - nothing is consumed. This replaces an earlier design that used
/// static image-space geometry (distance from the calibrated baseline) to
/// decide whether a movement attempt had started, which broke under camera
/// distance/perspective changes: monocular 2D geometry can't reliably
/// answer a temporal question ("has a jump begun?"), only a genuine
/// airborne event can.
///
/// Airborne/landing detection is temporal, not a single-frame threshold:
/// the ankle/foot vertical position relative to the calibrated ground
/// baseline (with hip rise as supporting corroboration - never sufficient
/// on its own) must hold continuously for a short debounce window before
/// either event is confirmed, so isolated ML Kit jitter can't fabricate an
/// airborne event or a landing. All of this uses raw per-frame landmark
/// positions, never an EMA - smoothing lags too much for a fast transition.
///
/// The jump apex is never chased causally. Once a landing is confirmed, the
/// engine looks back through the raw hip-Y samples collected during the
/// confirmed airborne window and takes their minimum - that retrospective
/// minimum is the apex. Jump height is the calibrated-scale conversion of
/// (standing hip baseline - apex), which is the only height measurement in
/// this iteration: flight-time-based height was considered but the current
/// camera/ML Kit pipeline exposes no capture timestamp for a Pose frame
/// (only wall-clock processing time, skewed by frame-skip and inference
/// latency), so it was deferred rather than built on an unreliable clock.
///
/// Horizontal drift is a validity check on an already-confirmed jump, never
/// a trigger: it's measured only across the confirmed airborne window and
/// can mark that attempt invalid, but never prevents the attempt from
/// existing or being counted.
class VerticalJumpEngine extends ExerciseEngine {
  VerticalJumpEngine({required this.userHeightCm});

  final double userHeightCm;

  static const int kMaxAttempts = 3;

  static const String _setupInstruction =
      'Stand facing the camera, about 2-3 meters back, with your entire '
      'body visible from head to feet. Hold still to calibrate, then '
      'perform up to $kMaxAttempts maximum-effort vertical jumps, one at a '
      'time. No running or stepping approach - jump straight up from a '
      'standing position and stay roughly in place.';

  /// How long a standing position must hold, both for the initial
  /// calibration and when re-confirming standing baseline after an attempt.
  static const Duration _kStabilityWindow = Duration(milliseconds: 1300);

  /// How long the airborne evidence (ankle + supporting hip rise) must hold
  /// continuously before a takeoff is confirmed - the temporal debounce
  /// that keeps a single noisy frame from fabricating an airborne event.
  static const Duration _kAirborneConfirmationDuration = Duration(milliseconds: 150);

  /// How long the ankle must stay back near the ground baseline before a
  /// landing is confirmed - so a single noisy near-baseline frame mid-flight
  /// doesn't end the attempt early.
  static const Duration _kLandingDebounce = Duration(milliseconds: 180);

  /// Safety net from a confirmed takeoff: real human airborne time plus
  /// landing debounce is well under this, so exceeding it means tracking
  /// was lost during a genuine, already-confirmed jump.
  static const Duration _kMaxAirborneDuration = Duration(milliseconds: 2500);

  /// Consecutive not-fully-visible frames tolerated during a confirmed
  /// airborne window before the attempt is abandoned as insufficient data.
  static const int _kMaxConsecutiveNotVisibleFrames = 10;

  // The fractions below are normalized by the athlete's own calibrated body
  // scale (standing hip-to-ankle vertical pixel span), so they hold
  // regardless of camera distance or athlete height. Starting values are
  // conservative estimates pending physical tuning.

  /// Ankle rise above its calibrated ground baseline, as a fraction of body
  /// scale, required as airborne evidence - the primary signal, since the
  /// ankle leaving the ground is what actually distinguishes a jump from a
  /// deep knee bend.
  static const double _kAnkleAirborneRiseFraction = 0.04;

  /// Hip rise above baseline, as a fraction of body scale, required as
  /// supporting evidence alongside the ankle signal. Never sufficient by
  /// itself - hip movement alone must never confirm a jump.
  static const double _kHipAirborneRiseFraction = 0.06;

  /// How close the ankle must return to the standing baseline to count as
  /// landed.
  static const double _kAnkleLandingToleranceFraction = 0.04;

  /// How close hip/ankle must be to the known baseline, held continuously
  /// for [_kStabilityWindow], to re-arm the next attempt after a confirmed
  /// jump. Deliberately looser than a calibration-grade tolerance: this is
  /// checked against the athlete's original pre-jump calibration position,
  /// and a real landing naturally settles a bit off that exact spot (a
  /// small balance step, a slightly different stance width, minor
  /// forward/backward lean) without the athlete having moved out of
  /// position in any meaningful sense. Doubled from an initial 0.06 to 0.12
  /// - generous enough to absorb that normal post-landing settling on both
  /// hip and ankle, while still requiring the athlete back within roughly
  /// an eighth of their own calibrated hip-to-ankle span, nowhere close to
  /// "anywhere in frame."
  static const double _kRearmToleranceFraction = 0.12;

  /// Maximum horizontal hip drift from the calibrated baseline, measured
  /// only across a confirmed airborne window, tolerated before that jump is
  /// flagged invalid. A validity gate, not a perspective correction.
  static const double _kHorizontalDriftToleranceFraction = 0.25;

  _JumpState _state = _JumpState.calibrating;
  bool _isBodyVisible = false;

  // Calibration - a one-time reference snapshot. Never repeated or used as
  // an ongoing "is the athlete still standing like this" validator.
  DateTime? _stableSince;
  final List<double> _calHipY = [];
  final List<double> _calAnkleY = [];
  final List<double> _calHipX = [];
  double? _cmPerPixel;

  double? _baselineHipY;
  double? _baselineAnkleY;
  double? _baselineHipX;

  // Thresholds resolved once, from the athlete's calibrated body scale.
  double _ankleAirborneRisePx = 0;
  double _hipAirborneRisePx = 0;
  double _ankleLandingTolerancePx = 0;
  double _rearmTolerancePx = 0;
  double _driftTolerancePx = 0;

  // Re-arming after a confirmed attempt.
  DateTime? _rearmStableSince;

  // Airborne-candidate tracking while READY (pre-confirmation) and the
  // confirmed airborne window itself. The hip-Y sample buffer starts filling
  // as soon as a candidate streak begins, and is discarded unread if the
  // streak breaks before confirmation - only a confirmed airborne event
  // keeps its samples for the retrospective apex lookup.
  DateTime? _airborneCandidateSince;
  final List<double> _airborneHipYSamples = [];
  DateTime? _takeoffTime;
  DateTime? _landingCandidateSince;
  double _maxAbsHipXDriftPx = 0;
  int _consecutiveNotVisible = 0;

  final List<JumpAttemptResult> _attempts = [];

  List<JumpAttemptResult> get attempts => List.unmodifiable(_attempts);

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
  double? get groundGuideImageY => _baselineAnkleY;

  @override
  void reset() {
    _state = _JumpState.calibrating;
    _isBodyVisible = false;
    _stableSince = null;
    _calHipY.clear();
    _calAnkleY.clear();
    _calHipX.clear();
    _cmPerPixel = null;
    _baselineHipY = null;
    _baselineAnkleY = null;
    _baselineHipX = null;
    _ankleAirborneRisePx = 0;
    _hipAirborneRisePx = 0;
    _ankleLandingTolerancePx = 0;
    _rearmTolerancePx = 0;
    _driftTolerancePx = 0;
    _rearmStableSince = null;
    _attempts.clear();
    _resetAttemptState();
  }

  void _resetAttemptState() {
    _airborneCandidateSince = null;
    _airborneHipYSamples.clear();
    _takeoffTime = null;
    _landingCandidateSince = null;
    _maxAbsHipXDriftPx = 0;
    _consecutiveNotVisible = 0;
  }

  @override
  void processPose(Pose? pose) {
    if (_state == _JumpState.testComplete) return;

    final now = DateTime.now();

    if (pose == null || !isFullBodyVisible(pose)) {
      _handleNotVisible();
      return;
    }

    final hipY = averageHipY(pose);
    final ankleY = averageAnkleY(pose);
    final hipX = averageHipX(pose);
    if (hipY == null || ankleY == null || hipX == null) {
      _handleNotVisible();
      return;
    }

    _isBodyVisible = true;
    _consecutiveNotVisible = 0;

    switch (_state) {
      case _JumpState.calibrating:
        _processCalibration(pose, hipY, ankleY, hipX, now);
      case _JumpState.awaitingBaseline:
        _processAwaitingBaseline(hipY, ankleY, now);
      case _JumpState.ready:
        _processReady(hipY, ankleY, now);
      case _JumpState.airborne:
        _processAirborne(hipY, ankleY, hipX, now);
      case _JumpState.testComplete:
        break;
    }
  }

  void _handleNotVisible() {
    _isBodyVisible = false;
    switch (_state) {
      case _JumpState.calibrating:
        _stableSince = null;
        _calHipY.clear();
        _calAnkleY.clear();
        _calHipX.clear();
      case _JumpState.awaitingBaseline:
        _rearmStableSince = null;
      case _JumpState.ready:
        // No attempt exists yet - a dropout here just resets any
        // in-progress (unconfirmed) airborne candidate streak. Nothing is
        // consumed.
        _airborneCandidateSince = null;
        _airborneHipYSamples.clear();
      case _JumpState.airborne:
        // A genuine airborne event is already confirmed and in progress -
        // losing tracking here is a real problem for this attempt.
        _bumpNotVisible();
      case _JumpState.testComplete:
        break;
    }
  }

  void _bumpNotVisible() {
    _consecutiveNotVisible++;
    if (_consecutiveNotVisible > _kMaxConsecutiveNotVisibleFrames) {
      _finalizeAttempt(forcedReason: JumpInvalidReason.insufficientData);
    }
  }

  double _average(List<double> values) => values.reduce((a, b) => a + b) / values.length;

  void _processCalibration(
    Pose pose,
    double hipY,
    double ankleY,
    double hipX,
    DateTime now,
  ) {
    _cmPerPixel ??= () {
      final heightPx = estimateStandingHeightPixels(pose);
      if (heightPx == null || heightPx <= 0) return null;
      return cmPerPixel(heightPx, userHeightCm);
    }();

    _stableSince ??= now;
    _calHipY.add(hipY);
    _calAnkleY.add(ankleY);
    _calHipX.add(hipX);

    if (now.difference(_stableSince!) < _kStabilityWindow || _cmPerPixel == null) {
      return;
    }

    final avgHipY = _average(_calHipY);
    final avgAnkleY = _average(_calAnkleY);
    final avgHipX = _average(_calHipX);
    final bodyScalePx = avgAnkleY - avgHipY;

    if (bodyScalePx <= 0) {
      // Degenerate geometry (ankle above hip) - shouldn't happen standing
      // upright. Keep collecting rather than locking in a broken scale.
      _stableSince = null;
      _calHipY.clear();
      _calAnkleY.clear();
      _calHipX.clear();
      return;
    }

    _baselineHipY = avgHipY;
    _baselineAnkleY = avgAnkleY;
    _baselineHipX = avgHipX;
    _ankleAirborneRisePx = bodyScalePx * _kAnkleAirborneRiseFraction;
    _hipAirborneRisePx = bodyScalePx * _kHipAirborneRiseFraction;
    _ankleLandingTolerancePx = bodyScalePx * _kAnkleLandingToleranceFraction;
    _rearmTolerancePx = bodyScalePx * _kRearmToleranceFraction;
    _driftTolerancePx = bodyScalePx * _kHorizontalDriftToleranceFraction;
    // Calibration is a one-time snapshot: from here on it never re-checks
    // "is the athlete still standing like this" - it just handed off fixed
    // references and gets out of the way.
    _state = _JumpState.ready;
  }

  void _processAwaitingBaseline(double hipY, double ankleY, DateTime now) {
    final closeHip = (hipY - _baselineHipY!).abs() <= _rearmTolerancePx;
    final closeAnkle = (ankleY - _baselineAnkleY!).abs() <= _rearmTolerancePx;

    if (!closeHip || !closeAnkle) {
      _rearmStableSince = null;
      return;
    }

    _rearmStableSince ??= now;
    if (now.difference(_rearmStableSince!) >= _kStabilityWindow) {
      _state = _JumpState.ready;
    }
  }

  /// Continuous observation. There is no "attempt started" event here: this
  /// only ever looks for airborne evidence, and resets silently - no state
  /// change, no bookkeeping kept - whenever that evidence isn't present.
  /// Standing still, swaying, translating toward/away from the camera, or a
  /// full squat-and-recover all fall through here indefinitely without
  /// consequence, because ankle rise (which none of those produce) is
  /// required alongside hip rise.
  void _processReady(double hipY, double ankleY, DateTime now) {
    final hipRise = _baselineHipY! - hipY;
    final ankleRise = _baselineAnkleY! - ankleY;
    final looksAirborne = ankleRise >= _ankleAirborneRisePx && hipRise >= _hipAirborneRisePx;

    if (!looksAirborne) {
      _airborneCandidateSince = null;
      _airborneHipYSamples.clear();
      return;
    }

    _airborneCandidateSince ??= now;
    _airborneHipYSamples.add(hipY);

    if (now.difference(_airborneCandidateSince!) >= _kAirborneConfirmationDuration) {
      _state = _JumpState.airborne;
      _takeoffTime = _airborneCandidateSince;
      _maxAbsHipXDriftPx = 0;
    }
  }

  /// A genuine airborne event is already confirmed. From here the only
  /// questions are: has the athlete landed, and did the confirmed jump stay
  /// within validity tolerances - never whether the attempt "counts".
  void _processAirborne(double hipY, double ankleY, double hipX, DateTime now) {
    _airborneHipYSamples.add(hipY);
    _trackDrift(hipX);

    final ankleRise = _baselineAnkleY! - ankleY;
    final looksLanded = ankleRise <= _ankleLandingTolerancePx;

    if (looksLanded) {
      _landingCandidateSince ??= now;
      if (now.difference(_landingCandidateSince!) >= _kLandingDebounce) {
        _finalizeAttempt();
        return;
      }
    } else {
      _landingCandidateSince = null;
    }

    if (now.difference(_takeoffTime!) > _kMaxAirborneDuration) {
      _finalizeAttempt(forcedReason: JumpInvalidReason.insufficientData);
    }
  }

  void _trackDrift(double hipX) {
    final drift = (hipX - _baselineHipX!).abs();
    if (drift > _maxAbsHipXDriftPx) _maxAbsHipXDriftPx = drift;
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
    } else if (_maxAbsHipXDriftPx > _driftTolerancePx) {
      result = JumpAttemptResult(
        attemptNumber: attemptNumber,
        isValid: false,
        invalidReason: JumpInvalidReason.excessiveDrift,
      );
    } else {
      // Retrospective apex: the minimum raw hip Y reached anywhere during
      // the confirmed airborne window, found only now that the window is
      // closed - never chased causally frame-by-frame.
      final minHipY = _airborneHipYSamples.reduce((a, b) => a < b ? a : b);
      final heightPx = _baselineHipY! - minHipY;
      final heightCm = heightPx * _cmPerPixel!;
      result = JumpAttemptResult(attemptNumber: attemptNumber, isValid: true, heightCm: heightCm);
    }

    _attempts.add(result);
    _resetAttemptState();

    if (_attempts.length >= kMaxAttempts) {
      _state = _JumpState.testComplete;
    } else {
      _state = _JumpState.awaitingBaseline;
      _rearmStableSince = null;
    }
  }

  String _reasonLabel(JumpInvalidReason reason) => switch (reason) {
    JumpInvalidReason.excessiveDrift => 'excessive horizontal drift',
    JumpInvalidReason.insufficientData => 'tracking lost',
  };

  String _attemptsSummary() {
    return _attempts
        .map((a) {
          if (a.isValid) return 'Attempt ${a.attemptNumber}: ${a.heightCm!.toStringAsFixed(1)} cm';
          return 'Attempt ${a.attemptNumber}: Invalid (${_reasonLabel(a.invalidReason!)})';
        })
        .join('   •   ');
  }

  @override
  ExerciseStatus get status {
    switch (_state) {
      case _JumpState.calibrating:
        if (!_isBodyVisible) {
          return ExerciseStatus(
            primaryText: _setupInstruction,
            secondaryText: 'Body not detected',
            isBodyVisible: false,
          );
        }
        if (_stableSince == null) {
          return const ExerciseStatus(
            primaryText: 'Hold a standing position to calibrate',
            isBodyVisible: true,
          );
        }
        final elapsedMs = DateTime.now().difference(_stableSince!).inMilliseconds;
        final pct = (elapsedMs / _kStabilityWindow.inMilliseconds * 100)
            .clamp(0, 100)
            .toStringAsFixed(0);
        return ExerciseStatus(
          primaryText: 'Calibrating... hold still ($pct%)',
          isBodyVisible: true,
        );

      case _JumpState.awaitingBaseline:
        return ExerciseStatus(
          primaryText: 'Return to standing',
          secondaryText: 'Hold still to start Attempt ${_attempts.length + 1}/$kMaxAttempts',
          isBodyVisible: _isBodyVisible,
        );

      case _JumpState.ready:
        return ExerciseStatus(
          primaryText: 'Attempt ${_attempts.length + 1}/$kMaxAttempts - Ready',
          secondaryText: _airborneCandidateSince != null
              ? 'Movement detected - jump!'
              : 'Jump when ready',
          isBodyVisible: _isBodyVisible,
        );

      case _JumpState.airborne:
        return ExerciseStatus(
          primaryText: 'Attempt ${_attempts.length + 1}/$kMaxAttempts - Airborne',
          isBodyVisible: _isBodyVisible,
        );

      case _JumpState.testComplete:
        final best = bestValidHeightCm;
        return ExerciseStatus(
          primaryText: best != null
              ? 'Best Jump: ${best.toStringAsFixed(1)} cm'
              : 'No valid jump recorded',
          secondaryText: _attemptsSummary(),
          isBodyVisible: _isBodyVisible,
        );
    }
  }
}
