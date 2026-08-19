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

  int _consecutiveUncertain = 0;
  CheckStatus _formStatus = CheckStatus.uncertain;
  String _formReason = '';
  bool _isBodyVisible = false;

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
    _consecutiveUncertain = 0;
    _formStatus = CheckStatus.uncertain;
    _formReason = '';
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
    switch (_phase) {
      case _CyclePhase.top:
        if (angle < config.topAngleThresholdDeg) {
          _phase = _CyclePhase.descending;
          _descentMinAngle = angle;
        }
      case _CyclePhase.descending:
        final currentMin = _descentMinAngle;
        _descentMinAngle = currentMin == null || angle < currentMin ? angle : currentMin;

        if (angle >= config.topAngleThresholdDeg) {
          // Recovered all the way back to top without ever reversing out of
          // a sufficient bottom - aborted, no rep.
          _phase = _CyclePhase.top;
          _descentMinAngle = null;
        } else if (angle - _descentMinAngle! >= _reversalThresholdDeg) {
          // The angle has risen a non-trivial amount off the lowest point
          // reached during this descent - a genuine reversal, not sensor
          // noise. Judge depth from the tracked minimum, not this frame's
          // instantaneous value.
          if (_descentMinAngle! <= config.bottomAngleThresholdDeg) {
            _phase = _CyclePhase.bottom;
          } else {
            // Insufficient depth - don't count a rep. Keep watching for
            // either a real bottom or a full recovery to top from here.
            _descentMinAngle = angle;
          }
        }
      case _CyclePhase.bottom:
        if (angle > config.bottomAngleThresholdDeg) {
          _phase = _CyclePhase.ascending;
        }
      case _CyclePhase.ascending:
        if (angle >= config.topAngleThresholdDeg) {
          final now = DateTime.now();
          if (_lastRepTime == null || now.difference(_lastRepTime!) >= config.minRepInterval) {
            _repCount++;
            _lastRepTime = now;
          }
          _phase = _CyclePhase.top;
          _descentMinAngle = null;
        } else if (angle <= config.bottomAngleThresholdDeg) {
          _phase = _CyclePhase.bottom; // Slipped back down before completing.
        }
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
    return ExerciseStatus(
      primaryText: 'Reps: $_repCount',
      secondaryText: 'Form: $formText   •   Phase: $_phaseLabel',
      isBodyVisible: true,
    );
  }
}
