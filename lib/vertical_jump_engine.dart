import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import 'exercise_engine.dart';
import 'pose_utils.dart';

/// Why a jump attempt was rejected. Kept deliberately small - just enough to
/// distinguish the failure modes the protocol actually cares about.
enum JumpInvalidReason {
  /// A qualifying whole-body movement started (e.g. a countermovement dip)
  /// but no genuine airborne phase ever followed it.
  notAJump,

  /// Horizontal hip displacement from the calibrated baseline exceeded
  /// tolerance at some point during the attempt.
  excessiveDrift,

  /// A second liftoff was detected before the first landing was confirmed.
  multipleJump,

  /// Tracking was lost (landmarks not visible, or no reliable apex/landing
  /// signal) for too long during the attempt.
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

enum _JumpState { calibrating, awaitingBaseline, armed, airborne, falling, testComplete }

/// Standing vertical jump test: three maximum-effort attempts, scored on the
/// best valid jump height.
///
/// Self-contained by design - owns calibration stability, takeoff/airborne/
/// apex/landing detection, attempt validity, and best-of-3 scoring directly,
/// rather than sitting on top of the angle-cycle rep-counting mechanics used
/// by push-ups/squats (which don't fit a single-attempt ballistic movement).
///
/// Primary measurement is vertical displacement of the hip midpoint between
/// the calibrated standing baseline and the apex reached during a validated
/// airborne phase. The ankle/foot baseline - not the hip - is the evidence
/// used to decide whether an airborne phase happened at all, so a deep knee
/// bend (hips moving without ever leaving the ground) can't be scored as a
/// jump.
///
/// All movement-event detection (takeoff, apex, landing) uses raw per-frame
/// landmark positions, never an EMA - smoothing lags too much to catch a
/// fast takeoff/apex transition reliably.
class VerticalJumpEngine extends ExerciseEngine {
  VerticalJumpEngine({required this.userHeightCm});

  final double userHeightCm;

  static const int kMaxAttempts = 3;

  static const String _setupInstruction =
      'Stand facing the camera, about 2-3 meters back, with your entire '
      'body visible from head to feet. Hold still to calibrate, then '
      'perform up to $kMaxAttempts maximum-effort vertical jumps, one at a '
      'time. No running or stepping approach - jump straight up from a '
      'standing position.';

  /// How long a standing position must hold, both for the initial
  /// calibration and when re-confirming standing baseline between attempts.
  static const Duration _kStabilityWindow = Duration(milliseconds: 1300);

  /// Small temporal tolerance so a single noisy frame near the ground
  /// baseline doesn't finalize a landing prematurely.
  static const Duration _kLandingDebounce = Duration(milliseconds: 180);

  /// Safety net for an armed attempt that starts a qualifying movement but
  /// never resolves into either a takeoff or a return to standing.
  static const Duration _kAttemptTimeout = Duration(seconds: 5);

  /// Safety net from takeoff: real human airborne time is well under this,
  /// so exceeding it without a confirmed apex means tracking was lost.
  static const Duration _kMaxAirborneToApexDuration = Duration(milliseconds: 1200);

  /// Safety net from apex: if landing evidence never arrives, tracking was
  /// lost during descent.
  static const Duration _kMaxFallingToLandingDuration = Duration(milliseconds: 2500);

  /// Consecutive not-fully-visible frames tolerated during a live attempt
  /// before it's abandoned as insufficient data.
  static const int _kMaxConsecutiveNotVisibleFrames = 10;

  // All of the fractions below are normalized by the athlete's own
  // calibrated body scale (standing hip-to-ankle vertical pixel span), so
  // they hold regardless of camera distance or athlete height. Starting
  // values are conservative estimates pending physical tuning.

  /// Minimum deviation of the hip-to-ankle vertical span from its
  /// calibrated standing value, as a fraction of body scale, that counts as
  /// "a genuine movement attempt started" (as opposed to idle standing sway
  /// or repositioning). The span - not raw distance from the baseline - is
  /// the signal: a countermovement dip or upward drive is knee/hip flexion,
  /// which changes the span; stepping back, swaying, or drifting off the
  /// calibrated baseline moves the hip and ankle landmarks together and
  /// leaves the span essentially unchanged. This keeps the dotted baseline
  /// a measurement reference only, never an attempt-start trigger.
  /// Deliberately smaller than the takeoff thresholds below so it fires on
  /// the countermovement dip before liftoff.
  static const double _kQualifyingMovementFraction = 0.05;

  /// Hip rise above baseline, as a fraction of body scale, required as one
  /// of the two takeoff conditions.
  static const double _kHipTakeoffRiseFraction = 0.06;

  /// Ankle rise above baseline, as a fraction of body scale, required as
  /// the other takeoff condition - the primary evidence of leaving the
  /// ground, independent of hip height.
  static const double _kAnkleTakeoffRiseFraction = 0.04;

  /// How far the hip must rise back up from its tracked in-flight minimum
  /// to confirm that minimum was a genuine apex (reversal), not noise.
  static const double _kApexReversalFraction = 0.02;

  /// How close the ankle must return to the standing baseline to count as
  /// having landed.
  static const double _kAnkleLandingToleranceFraction = 0.04;

  /// How close hip/ankle must be to the known baseline, held continuously
  /// for [_kStabilityWindow], to re-arm the next attempt.
  static const double _kRearmToleranceFraction = 0.06;

  /// Maximum horizontal hip drift from the calibrated baseline tolerated
  /// during an attempt before it's flagged as not a primarily-vertical
  /// jump. A validity gate, not a perspective correction.
  static const double _kHorizontalDriftToleranceFraction = 0.25;

  _JumpState _state = _JumpState.calibrating;
  bool _isBodyVisible = false;

  // Calibration.
  DateTime? _stableSince;
  final List<double> _calHipY = [];
  final List<double> _calAnkleY = [];
  final List<double> _calHipX = [];
  double? _cmPerPixel;

  double? _baselineHipY;
  double? _baselineAnkleY;
  double? _baselineHipX;

  /// Calibrated standing hip-to-ankle vertical pixel span. Used as the
  /// qualifying-movement reference (see [_kQualifyingMovementFraction]),
  /// distinct from the individual baselines above.
  double _bodyScalePx = 0;

  // Thresholds resolved once, from the athlete's calibrated body scale.
  double _qualifyingMovementPx = 0;
  double _hipTakeoffRisePx = 0;
  double _ankleTakeoffRisePx = 0;
  double _apexReversalPx = 0;
  double _ankleLandingTolerancePx = 0;
  double _rearmTolerancePx = 0;
  double _driftTolerancePx = 0;

  // Between-attempt re-arming.
  DateTime? _rearmStableSince;

  // Per-attempt tracking.
  bool _qualifyingMovementSeen = false;
  DateTime? _attemptStartTime;
  DateTime? _takeoffTime;
  DateTime? _apexTime;
  double? _runningMinHipY;
  double? _apexHipY;
  bool _multipleJumpDetected = false;
  double _maxAbsHipXDriftPx = 0;
  DateTime? _landingCandidateSince;
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
    _bodyScalePx = 0;
    _qualifyingMovementPx = 0;
    _hipTakeoffRisePx = 0;
    _ankleTakeoffRisePx = 0;
    _apexReversalPx = 0;
    _ankleLandingTolerancePx = 0;
    _rearmTolerancePx = 0;
    _driftTolerancePx = 0;
    _rearmStableSince = null;
    _attempts.clear();
    _resetAttemptState();
  }

  void _resetAttemptState() {
    _qualifyingMovementSeen = false;
    _attemptStartTime = null;
    _takeoffTime = null;
    _apexTime = null;
    _runningMinHipY = null;
    _apexHipY = null;
    _multipleJumpDetected = false;
    _maxAbsHipXDriftPx = 0;
    _landingCandidateSince = null;
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
      case _JumpState.armed:
        _processArmed(hipY, ankleY, hipX, now);
      case _JumpState.airborne:
        _processAirborne(hipY, hipX, now);
      case _JumpState.falling:
        _processFalling(hipY, ankleY, hipX, now);
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
      case _JumpState.armed:
        // No attempt has genuinely started yet if there's been no
        // qualifying movement - a transient dropout while just standing
        // and waiting shouldn't cost anything.
        if (_qualifyingMovementSeen) _bumpNotVisible();
      case _JumpState.airborne:
      case _JumpState.falling:
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
    _bodyScalePx = bodyScalePx;
    _qualifyingMovementPx = bodyScalePx * _kQualifyingMovementFraction;
    _hipTakeoffRisePx = bodyScalePx * _kHipTakeoffRiseFraction;
    _ankleTakeoffRisePx = bodyScalePx * _kAnkleTakeoffRiseFraction;
    _apexReversalPx = bodyScalePx * _kApexReversalFraction;
    _ankleLandingTolerancePx = bodyScalePx * _kAnkleLandingToleranceFraction;
    _rearmTolerancePx = bodyScalePx * _kRearmToleranceFraction;
    _driftTolerancePx = bodyScalePx * _kHorizontalDriftToleranceFraction;
    _state = _JumpState.armed;
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
      _state = _JumpState.armed;
    }
  }

  void _processArmed(double hipY, double ankleY, double hipX, DateTime now) {
    _trackDrift(hipX);

    final hipRise = _baselineHipY! - hipY;
    final ankleRise = _baselineAnkleY! - ankleY;

    if (hipRise >= _hipTakeoffRisePx && ankleRise >= _ankleTakeoffRisePx) {
      _state = _JumpState.airborne;
      _takeoffTime = now;
      _runningMinHipY = hipY;
      return;
    }

    // Genuine jump-initiating movement (a countermovement dip or an early
    // upward drive) is knee/hip flexion, so it changes the athlete's own
    // hip-to-ankle span. Incidental movement - stepping back, swaying, ML
    // Kit jitter - shifts the hip and ankle landmarks together and leaves
    // that span roughly unchanged, even though it moves the athlete away
    // from the calibrated baseline. This is what lets the dotted baseline
    // stay a measurement reference without doubling as an attempt trigger.
    final hipAnkleSpan = ankleY - hipY;
    final spanDeviation = (_bodyScalePx - hipAnkleSpan).abs();
    if (spanDeviation >= _qualifyingMovementPx) {
      _qualifyingMovementSeen = true;
      _attemptStartTime ??= now;
    } else if (_qualifyingMovementSeen) {
      // A real movement attempt started and fully recovered back to
      // standing without ever leaving the ground - a countermovement dip
      // with no jump, not a valid attempt.
      _finalizeAttempt(forcedReason: JumpInvalidReason.notAJump);
      return;
    }

    if (_qualifyingMovementSeen && now.difference(_attemptStartTime!) > _kAttemptTimeout) {
      _finalizeAttempt(forcedReason: JumpInvalidReason.notAJump);
    }
  }

  void _processAirborne(double hipY, double hipX, DateTime now) {
    _trackDrift(hipX);

    if (hipY < _runningMinHipY!) _runningMinHipY = hipY;

    final reversal = hipY - _runningMinHipY!;
    if (reversal >= _apexReversalPx) {
      _apexHipY = _runningMinHipY;
      _apexTime = now;
      _state = _JumpState.falling;
      return;
    }

    if (now.difference(_takeoffTime!) > _kMaxAirborneToApexDuration) {
      _finalizeAttempt(forcedReason: JumpInvalidReason.insufficientData);
    }
  }

  void _processFalling(double hipY, double ankleY, double hipX, DateTime now) {
    _trackDrift(hipX);

    final hipRise = _baselineHipY! - hipY;
    final ankleRise = _baselineAnkleY! - ankleY;
    final reAscending = hipRise >= _hipTakeoffRisePx && ankleRise >= _ankleTakeoffRisePx;
    if (reAscending) _multipleJumpDetected = true;

    final ankleNearBaseline = ankleRise <= _ankleLandingTolerancePx;
    if (ankleNearBaseline && !reAscending) {
      _landingCandidateSince ??= now;
      if (now.difference(_landingCandidateSince!) >= _kLandingDebounce) {
        _finalizeAttempt();
        return;
      }
    } else {
      _landingCandidateSince = null;
    }

    if (now.difference(_apexTime!) > _kMaxFallingToLandingDuration) {
      _finalizeAttempt(forcedReason: JumpInvalidReason.insufficientData);
    }
  }

  void _trackDrift(double hipX) {
    final drift = (hipX - _baselineHipX!).abs();
    if (drift > _maxAbsHipXDriftPx) _maxAbsHipXDriftPx = drift;
  }

  void _finalizeAttempt({JumpInvalidReason? forcedReason}) {
    final attemptNumber = _attempts.length + 1;
    final JumpAttemptResult result;

    if (forcedReason != null) {
      result = JumpAttemptResult(
        attemptNumber: attemptNumber,
        isValid: false,
        invalidReason: forcedReason,
      );
    } else if (_multipleJumpDetected) {
      result = JumpAttemptResult(
        attemptNumber: attemptNumber,
        isValid: false,
        invalidReason: JumpInvalidReason.multipleJump,
      );
    } else if (_maxAbsHipXDriftPx > _driftTolerancePx) {
      result = JumpAttemptResult(
        attemptNumber: attemptNumber,
        isValid: false,
        invalidReason: JumpInvalidReason.excessiveDrift,
      );
    } else if (_apexHipY == null) {
      result = JumpAttemptResult(
        attemptNumber: attemptNumber,
        isValid: false,
        invalidReason: JumpInvalidReason.insufficientData,
      );
    } else {
      final heightPx = _baselineHipY! - _apexHipY!;
      final heightCm = heightPx * _cmPerPixel!;
      result = JumpAttemptResult(attemptNumber: attemptNumber, isValid: true, heightCm: heightCm);
    }

    _attempts.add(result);
    _resetAttemptState();

    if (_attempts.length >= kMaxAttempts) {
      _state = _JumpState.testComplete;
    } else {
      _state = _JumpState.awaitingBaseline;
    }
  }

  String _reasonLabel(JumpInvalidReason reason) => switch (reason) {
    JumpInvalidReason.notAJump => 'not a jump - no airborne phase',
    JumpInvalidReason.excessiveDrift => 'excessive horizontal drift',
    JumpInvalidReason.multipleJump => 'multiple jumps in one attempt',
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

      case _JumpState.armed:
        return ExerciseStatus(
          primaryText: 'Attempt ${_attempts.length + 1}/$kMaxAttempts - Ready',
          secondaryText: _qualifyingMovementSeen ? 'Movement detected - jump!' : 'Jump when ready',
          isBodyVisible: _isBodyVisible,
        );

      case _JumpState.airborne:
        return ExerciseStatus(
          primaryText: 'Attempt ${_attempts.length + 1}/$kMaxAttempts - Airborne',
          isBodyVisible: _isBodyVisible,
        );

      case _JumpState.falling:
        return ExerciseStatus(
          primaryText: 'Attempt ${_attempts.length + 1}/$kMaxAttempts - Landing',
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
