import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import 'exercise_config.dart';
import 'exercise_engine.dart';
import 'form_check.dart';
import 'pose_utils.dart';
import 'sided_pose.dart';

enum _CyclePhase { top, descending, bottom, ascending }

/// Reusable rep-cycle mechanics for any exercise whose repetitions are
/// characterized by a single joint angle cycling TOP -> DESCENDING ->
/// BOTTOM -> ASCENDING -> TOP. Contains no exercise-specific biomechanics -
/// everything exercise-specific (which landmarks, which thresholds, which
/// form checks) lives in the [ExerciseConfig] it's constructed with.
class AngleCycleEngine extends ExerciseEngine {
  AngleCycleEngine({required this.config});

  final ExerciseConfig config;

  /// Confirmed violations tolerated before the attempt is terminated - two
  /// warnings, then termination on the third.
  static const int _maxWarnings = 2;

  /// Minimum rise (in degrees) from the tracked descent minimum required to
  /// treat the movement as a genuine direction reversal rather than sensor
  /// noise. Chosen from the middle of the requested 5-8 degree range.
  static const double _reversalThresholdDeg = 6.0;

  /// Size of the trailing raw-position window sampled for
  /// [BottomEventValidator]s. Small and fixed - just enough to average out
  /// single-frame ML Kit jitter around a BOTTOM event, not a smoothing
  /// state machine.
  static const int _eventSampleWindow = 5;

  bool? _preferredSideIsLeft;

  bool _calibrated = false;
  DateTime? _stableSince;
  final List<FormCheckContext> _stabilitySamples = [];
  ExerciseReference? _reference;
  String _calibrationMessage = '';

  double? _smoothedAngle;
  _CyclePhase _phase = _CyclePhase.top;
  int _repCount = 0;
  DateTime? _lastRepTime;

  /// Lowest raw (unsmoothed) movement-signal angle observed during the
  /// current DESCENDING phase. Used to detect a genuine bottom independent
  /// of the EMA-smoothed angle, which lags too much to reliably catch fast
  /// reps.
  double? _descentMinAngle;

  /// Trailing raw hip/shoulder-midpoint Y readings, refreshed every
  /// tracking frame regardless of phase, so a [BottomEventValidator] has a
  /// small jitter-robust window to sample from whenever a BOTTOM event is
  /// confirmed.
  final List<double> _hipYWindow = [];
  final List<double> _shoulderYWindow = [];

  int _consecutiveUncertain = 0;
  CheckStatus _formStatus = CheckStatus.uncertain;
  String _formReason = '';
  bool _isBodyVisible = false;

  /// Advisory-only note (e.g. excessive ROM) shown alongside the form
  /// status. Distinct from [_formReason]/[_formStatus]: never gates rep
  /// counting or the warning/termination lifecycle. Null when no config
  /// declares [ExerciseConfig.excessiveRomDeg] or the signal isn't
  /// currently triggered.
  String? _formAdvisory;

  // Test-attempt lifecycle: separate from FormCheck verdicts above. Tracks
  // how long a definite INVALID status has persisted, independent of the
  // frame-by-frame VALID/INVALID/UNCERTAIN judgment itself.
  DateTime? _invalidSince;
  bool _violationConfirmedThisEpisode = false;
  int _warningCount = 0;
  bool _terminated = false;

  @override
  void reset() {
    _preferredSideIsLeft = null;
    _calibrated = false;
    _stableSince = null;
    _stabilitySamples.clear();
    _reference = null;
    _calibrationMessage = config.setupInstruction;
    _smoothedAngle = null;
    _phase = _CyclePhase.top;
    _repCount = 0;
    _lastRepTime = null;
    _descentMinAngle = null;
    _hipYWindow.clear();
    _shoulderYWindow.clear();
    _consecutiveUncertain = 0;
    _formStatus = CheckStatus.uncertain;
    _formReason = '';
    _formAdvisory = null;
    _isBodyVisible = false;
    _invalidSince = null;
    _violationConfirmedThisEpisode = false;
    _warningCount = 0;
    _terminated = false;
  }

  FormCheckResult _evaluateChecks(FormCheckContext context) {
    for (final check in config.formChecks) {
      final result = check.evaluate(context);
      if (result.status != CheckStatus.valid) return result;
    }
    return FormCheckResult.ok;
  }

  double? _primaryAngle(FormCheckContext context) {
    final sided = context.sidedPose;
    if (sided == null) return null;
    final (a, b, c) = config.angleLandmarks;
    final pa = sided[a];
    final pb = sided[b];
    final pc = sided[c];
    if (pa == null || pb == null || pc == null) return null;
    return angleBetweenPoints(pa, pb, pc);
  }

  /// TOP threshold for this attempt: [ExerciseConfig.topAngleThresholdDeg]
  /// if fixed, otherwise the athlete's own calibrated baseline stored under
  /// [ExerciseConfig.topAngleReferenceKey]. Null only if calibration hasn't
  /// produced that reference value yet - shouldn't happen once
  /// [_calibrated] is true given [ExerciseConfig]'s constructor assertion.
  double? get _topThreshold =>
      config.topAngleThresholdDeg ??
      (config.topAngleReferenceKey != null ? _reference?.get(config.topAngleReferenceKey!) : null);

  /// BOTTOM threshold for this attempt: [ExerciseConfig.bottomAngleThresholdDeg]
  /// if fixed, otherwise [_topThreshold] minus [ExerciseConfig.targetRomDeg].
  double? get _bottomThreshold {
    final fixed = config.bottomAngleThresholdDeg;
    if (fixed != null) return fixed;
    final top = _topThreshold;
    final rom = config.targetRomDeg;
    if (top == null || rom == null) return null;
    return top - rom;
  }

  ExerciseReference _buildReference(List<FormCheckContext> samples) {
    final values = <String, double>{};
    for (final check in config.formChecks) {
      final key = check.referenceKey;
      if (key == null) continue;
      final samplesForCheck =
          samples.map(check.sampleValue).whereType<double>().toList();
      if (samplesForCheck.isEmpty) continue;
      values[key] = samplesForCheck.reduce((a, b) => a + b) / samplesForCheck.length;
    }
    return ExerciseReference(values);
  }

  @override
  void processPose(Pose? pose) {
    // Attempt is over: freeze the rep count and ignore everything from here
    // on. No auto-restart, no further phase advancement.
    if (_terminated) return;

    if (pose == null) {
      _isBodyVisible = false;
      if (!_calibrated) {
        _stableSince = null;
        _stabilitySamples.clear();
        _calibrationMessage = config.setupInstruction;
      } else {
        _registerCheckResult(
          const FormCheckResult(CheckStatus.uncertain, 'Body not detected'),
        );
      }
      return;
    }

    _isBodyVisible = true;

    if (!_calibrated) {
      _processCalibrationFrame(pose);
    } else {
      _processTrackingFrame(pose);
    }
  }

  void _processCalibrationFrame(Pose pose) {
    final sidedPose = resolveSidedPose(
      pose,
      requiredPoints: config.requiredPoints,
      confidenceThreshold: config.landmarkConfidenceThreshold,
      preferLeftSide: _preferredSideIsLeft,
    );
    if (sidedPose != null) _preferredSideIsLeft = sidedPose.isLeftSide;

    final context = FormCheckContext(pose: pose, sidedPose: sidedPose);
    final result = _evaluateChecks(context);

    if (result.status == CheckStatus.valid) {
      final isFirstFrameOfStreak = _stableSince == null;
      _stableSince ??= DateTime.now();
      _stabilitySamples.add(context);
      final elapsed = DateTime.now().difference(_stableSince!);

      if (elapsed >= config.stabilityWindow) {
        _reference = _buildReference(_stabilitySamples);
        _calibrated = true;
        _phase = _CyclePhase.top;
        _smoothedAngle = _primaryAngle(context);
        _calibrationMessage = 'Starting position locked';
      } else if (isFirstFrameOfStreak) {
        _calibrationMessage = 'Valid position detected - hold still...';
      } else {
        final pct = (elapsed.inMilliseconds / config.stabilityWindow.inMilliseconds * 100)
            .clamp(0, 100)
            .toStringAsFixed(0);
        _calibrationMessage = 'Hold still... $pct%';
      }
      return;
    }

    _stableSince = null;
    _stabilitySamples.clear();
    _calibrationMessage = sidedPose == null ? config.setupInstruction : result.reason;
  }

  void _processTrackingFrame(Pose pose) {
    final sidedPose = resolveSidedPose(
      pose,
      requiredPoints: config.requiredPoints,
      confidenceThreshold: config.landmarkConfidenceThreshold,
      preferLeftSide: _preferredSideIsLeft,
    );
    if (sidedPose != null) _preferredSideIsLeft = sidedPose.isLeftSide;

    final context = FormCheckContext(pose: pose, sidedPose: sidedPose, reference: _reference);
    final result = _evaluateChecks(context);

    final hipY = averageHipY(pose);
    if (hipY != null) _pushSample(_hipYWindow, hipY);
    final shoulderY = averageShoulderY(pose);
    if (shoulderY != null) _pushSample(_shoulderYWindow, shoulderY);

    // Smoothed angle keeps tracking whenever computable, independent of
    // check status, so tracking resumes cleanly once good form returns.
    // This EMA signal is retained purely for form/status purposes and is
    // never used to drive phase transitions.
    final rawAngle = _primaryAngle(context);
    if (rawAngle != null) {
      _smoothedAngle = _smoothedAngle == null
          ? rawAngle
          : config.emaAlpha * rawAngle + (1 - config.emaAlpha) * _smoothedAngle!;
    }

    // Phase transitions use the raw (unsmoothed) angle as the movement
    // signal, not the EMA above - the EMA's lag can prevent it from ever
    // reaching bottomAngleThresholdDeg during a fast rep even though the
    // real joint angle did.
    _registerCheckResult(result, movementAngle: rawAngle);
    _updateFormAdvisory(rawAngle);
  }

  /// Advisory-only companion to [_advancePhase]: never gates rep counting
  /// or the warning/termination lifecycle, purely surfaces
  /// [ExerciseConfig.excessiveRomMessage] in status text when the movement
  /// signal has drifted further from the TOP baseline than
  /// [ExerciseConfig.excessiveRomDeg] (e.g. a Controlled Crunch drifting
  /// toward a full sit-up). No-op for exercises that don't configure it.
  void _updateFormAdvisory(double? angle) {
    final excessiveRom = config.excessiveRomDeg;
    final message = config.excessiveRomMessage;
    if (excessiveRom == null || message == null) return;

    if (_phase == _CyclePhase.top) {
      _formAdvisory = null;
      return;
    }

    final top = _topThreshold;
    if (angle == null || top == null) return;

    if (top - angle > excessiveRom) _formAdvisory = message;
  }

  void _registerCheckResult(FormCheckResult result, {double? movementAngle}) {
    switch (result.status) {
      case CheckStatus.valid:
        _consecutiveUncertain = 0;
        _formStatus = CheckStatus.valid;
        _formReason = result.reason;
        if (movementAngle != null) _advancePhase(movementAngle);
      case CheckStatus.uncertain:
        _consecutiveUncertain++;
        _formReason = result.reason;
        if (_consecutiveUncertain > config.maxUncertainFrames) {
          _formStatus = CheckStatus.invalid;
          _invalidateTrajectory();
        } else {
          // Isolated ML Kit noise shouldn't destroy a legitimate rep: don't
          // advance the state machine, but don't invalidate it either.
          _formStatus = CheckStatus.uncertain;
        }
      case CheckStatus.invalid:
        _consecutiveUncertain = 0;
        _formStatus = CheckStatus.invalid;
        _formReason = result.reason;
        _invalidateTrajectory();
    }
    _updateLifecycle();
  }

  /// A fresh valid TOP is required to start a new attempt - whatever
  /// partial descent/ascent progress existed is discarded, no rep counted.
  void _invalidateTrajectory() {
    _phase = _CyclePhase.top;
    _descentMinAngle = null;
    _hipYWindow.clear();
    _shoulderYWindow.clear();
  }

  void _pushSample(List<double> window, double value) {
    window.add(value);
    if (window.length > _eventSampleWindow) window.removeAt(0);
  }

  /// Advances the warning/termination lifecycle from the current
  /// [_formStatus]. A confirmed violation is a definite INVALID status
  /// that has persisted continuously for at least
  /// [ExerciseConfig.sustainedInvalidConfirmation] - short blips don't
  /// count, so isolated noisy frames can't burn a warning. UNCERTAIN
  /// frames neither confirm nor clear an in-progress violation episode;
  /// only a return to VALID ends it, allowing a later, separate violation
  /// to warn again.
  void _updateLifecycle() {
    switch (_formStatus) {
      case CheckStatus.valid:
        _invalidSince = null;
        _violationConfirmedThisEpisode = false;
      case CheckStatus.invalid:
        final now = DateTime.now();
        _invalidSince ??= now;
        if (!_violationConfirmedThisEpisode &&
            now.difference(_invalidSince!) >= config.sustainedInvalidConfirmation) {
          _violationConfirmedThisEpisode = true;
          _registerConfirmedViolation();
        }
      case CheckStatus.uncertain:
        break;
    }
  }

  void _registerConfirmedViolation() {
    _warningCount++;
    if (_warningCount > _maxWarnings) {
      _terminated = true;
    }
  }

  void _advancePhase(double angle) {
    // Once calibrated, both resolve to real values for every exercise
    // config (either fixed, or the calibrated baseline +/- targetRomDeg -
    // see ExerciseConfig's constructor assertion). Bail defensively rather
    // than crash on the always-unexpected case where a reference value
    // hasn't materialized yet.
    final top = _topThreshold;
    final bottom = _bottomThreshold;
    if (top == null || bottom == null) return;

    switch (_phase) {
      case _CyclePhase.top:
        if (angle < top) {
          _phase = _CyclePhase.descending;
          _descentMinAngle = angle;
        }
      case _CyclePhase.descending:
        final currentMin = _descentMinAngle;
        _descentMinAngle = currentMin == null || angle < currentMin ? angle : currentMin;

        if (angle >= top) {
          // Recovered all the way back to top without ever reversing out of
          // a sufficient bottom - aborted, no rep.
          _phase = _CyclePhase.top;
          _descentMinAngle = null;
        } else if (angle - _descentMinAngle! >= _reversalThresholdDeg) {
          // The angle has risen a non-trivial amount off the lowest point
          // reached during this descent - a genuine reversal, not sensor
          // noise. Judge depth from the tracked minimum, not this frame's
          // instantaneous value.
          if (_descentMinAngle! <= bottom) {
            _confirmBottom(angle);
          } else {
            // Insufficient depth - don't count a rep. Keep watching for
            // either a real bottom or a full recovery to top from here.
            _descentMinAngle = angle;
          }
        }
      case _CyclePhase.bottom:
        if (angle > bottom) {
          _phase = _CyclePhase.ascending;
        }
      case _CyclePhase.ascending:
        if (angle >= top) {
          final now = DateTime.now();
          if (_lastRepTime == null || now.difference(_lastRepTime!) >= config.minRepInterval) {
            _repCount++;
            _lastRepTime = now;
          }
          _phase = _CyclePhase.top;
          _descentMinAngle = null;
        } else if (angle <= bottom) {
          _phase = _CyclePhase.bottom; // Slipped back down before completing.
        }
    }
  }

  /// Called when `AngleCycleEngine`'s knee-angle mechanics alone have
  /// confirmed a genuine BOTTOM (sufficient depth + a real reversal). This
  /// is the sole hook into [ExerciseConfig.bottomEventValidator]: the knee
  /// ROM state machine above is untouched, this just gates whether that
  /// already-detected event is accepted as representing real whole-body
  /// movement.
  void _confirmBottom(double angle) {
    final validator = config.bottomEventValidator;
    final reference = _reference;
    if (validator == null || reference == null) {
      _phase = _CyclePhase.bottom;
      return;
    }

    final result = validator.validate(
      BottomEventContext(
        reference: reference,
        hipYSamples: List.unmodifiable(_hipYWindow),
        shoulderYSamples: List.unmodifiable(_shoulderYWindow),
      ),
    );

    switch (result.outcome) {
      case BottomEventOutcome.valid:
        _phase = _CyclePhase.bottom;
      case BottomEventOutcome.noQualifyingAttempt:
      case BottomEventOutcome.insufficientDepth:
        // Either no real whole-body movement happened at all (e.g. a local
        // knee/ankle manipulation while standing still) or it happened but
        // didn't reach depth. Neither is a form violation - silently
        // abandon this trajectory back to TOP with no rep and no warning.
        _invalidateTrajectory();
      case BottomEventOutcome.formViolation:
        // A qualifying, sufficiently deep attempt broke a real form
        // constraint - a confirmed anti-cheat violation, not a silently
        // discarded rep. Registered immediately rather than through the
        // sustained ~800ms INVALID-frame debounce used for continuous
        // FormChecks: that debounce exists to filter noisy per-frame
        // signals, but this one-shot event decision is already smoothed via
        // the temporal sample window above.
        _formStatus = CheckStatus.invalid;
        _formReason = result.reason;
        _invalidateTrajectory();
        _violationConfirmedThisEpisode = true;
        _invalidSince ??= DateTime.now();
        _registerConfirmedViolation();
      case BottomEventOutcome.uncertain:
        // Not enough reliable displacement data yet - treat like an
        // insufficient-depth reading rather than penalizing the athlete for
        // a transient landmark dropout.
        _descentMinAngle = angle;
    }
  }

  String get _phaseLabel {
    switch (_phase) {
      case _CyclePhase.top:
        return 'TOP';
      case _CyclePhase.descending:
        return 'DESCENDING';
      case _CyclePhase.bottom:
        return 'BOTTOM';
      case _CyclePhase.ascending:
        return 'ASCENDING';
    }
  }

  @override
  ExerciseStatus get status {
    if (_terminated) {
      return ExerciseStatus(
        primaryText: 'TEST TERMINATED',
        secondaryText: 'Final rep count: $_repCount',
        isBodyVisible: _isBodyVisible,
      );
    }

    if (!_isBodyVisible) {
      return ExerciseStatus(
        primaryText: config.setupInstruction,
        secondaryText: 'Body not detected',
        isBodyVisible: false,
      );
    }

    if (!_calibrated) {
      return ExerciseStatus(
        primaryText: 'Calibrating',
        secondaryText: _calibrationMessage,
        isBodyVisible: true,
      );
    }

    if (_violationConfirmedThisEpisode && _warningCount > 0) {
      final message = _warningCount == 1
          ? 'FORM WARNING 1/2 — Return to the required push-up position'
          : 'FORM WARNING 2/2 — One more form violation will end the test';
      return ExerciseStatus(
        primaryText: message,
        secondaryText: 'Reps: $_repCount',
        isBodyVisible: true,
      );
    }

    final formLabel = _formStatus.name.toUpperCase();
    final formText = _formReason.isEmpty ? formLabel : '$formLabel - $_formReason';
    final advisoryText = _formAdvisory != null ? '   •   $_formAdvisory' : '';
    return ExerciseStatus(
      primaryText: 'Reps: $_repCount',
      secondaryText: 'Form: $formText   •   Phase: $_phaseLabel$advisoryText',
      isBodyVisible: true,
    );
  }
}
