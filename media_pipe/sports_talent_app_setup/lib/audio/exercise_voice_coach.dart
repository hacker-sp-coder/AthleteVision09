import '../angle_cycle_engine.dart';
import '../exercise_engine.dart';
import '../plank_engine.dart';
import '../vertical_jump_engine.dart';
import 'voice_feedback_service.dart';

/// Drives [VoiceFeedbackService] from the EXISTING exercise-engine state
/// for exactly three exercises (push-up, plank, vertical jump) - see
/// project report. Reads already-computed engine state (rep counts, hold
/// duration, calibration/ready/warning/termination flags - all exposed as
/// small read-only getters added to the three concrete engines) and
/// diffs it against what this class last spoke, so widget rebuilds and
/// repeated per-frame calls never cause duplicate announcements. Never
/// invents a new counter, timer, or calibration rule - every phrase here
/// traces back to an existing engine state/message.
///
/// [onFrame] is meant to be called once per processed pose frame (the
/// same place the screen already reads `engine.status`), not from
/// `build()`.
class ExerciseVoiceCoach {
  ExerciseVoiceCoach({required VoiceFeedbackService voice, required ExerciseType exerciseType})
    // ignore: prefer_initializing_formals
    : _voice = voice,
      _exerciseType = exerciseType,
      _supported =
          exerciseType == ExerciseType.pushUp ||
          exerciseType == ExerciseType.plank ||
          exerciseType == ExerciseType.verticalJump;

  final VoiceFeedbackService _voice;
  final ExerciseType _exerciseType;
  final bool _supported;

  static const Duration _formWarningCooldown = Duration(milliseconds: 1800);

  String? _lastCalibrationCategory;
  bool _wasCalibratedOrReady = false;
  int _lastRepOrAttemptCount = 0;
  int _lastPlankWholeSeconds = -1;
  bool _wasWarningActive = false;
  DateTime? _lastWarningSpokenAt;
  bool _terminalAnnounced = false;

  /// Resets all per-test tracking. Call once when a new test starts.
  void resetForNewTest() {
    _lastCalibrationCategory = null;
    _wasCalibratedOrReady = false;
    _lastRepOrAttemptCount = 0;
    _lastPlankWholeSeconds = -1;
    _wasWarningActive = false;
    _lastWarningSpokenAt = null;
    _terminalAnnounced = false;
  }

  /// Announces the start of the test, then whatever the engine's initial
  /// calibration message is - spoken once. Call right when the test
  /// becomes active (Start pressed), before the first [onFrame] call.
  void onTestStarted() {
    if (!_supported) return;
    resetForNewTest();
    final label = switch (_exerciseType) {
      ExerciseType.pushUp => 'Push-up test starting.',
      ExerciseType.plank => 'Plank test starting.',
      ExerciseType.verticalJump => 'Vertical jump test starting.',
      _ => null,
    };
    if (label != null) _voice.speak(label, priority: VoicePriority.high);
  }

  /// Call once per processed pose frame with the current engine and its
  /// current status. Diffs against previously-seen state; never speaks
  /// the same transition twice.
  void onFrame(ExerciseEngine engine, ExerciseStatus status) {
    if (!_supported || _terminalAnnounced) return;
    switch (_exerciseType) {
      case ExerciseType.pushUp:
        _onPushUpFrame(engine as AngleCycleEngine, status);
      case ExerciseType.plank:
        _onPlankFrame(engine as PlankEngine, status);
      case ExerciseType.verticalJump:
        _onVerticalJumpFrame(engine as VerticalJumpEngine, status);
      default:
        break;
    }
  }

  void _onPushUpFrame(AngleCycleEngine engine, ExerciseStatus status) {
    if (!engine.isCalibrated) {
      _speakCalibrationIfChanged(status);
      return;
    }
    if (!_wasCalibratedOrReady) {
      _wasCalibratedOrReady = true;
      _lastCalibrationCategory = null;
      _voice.speak("You're ready. Begin.", priority: VoicePriority.high);
    }

    if (engine.isTerminated) {
      _terminalAnnounced = true;
      _voice.speak('Test terminated.', priority: VoicePriority.high);
      return;
    }

    if (engine.repCount > _lastRepOrAttemptCount) {
      _lastRepOrAttemptCount = engine.repCount;
      _voice.speak('$_lastRepOrAttemptCount', priority: VoicePriority.medium);
    }

    _handleWarning(engine.hasActiveFormWarning, engine.formReason);
  }

  void _onPlankFrame(PlankEngine engine, ExerciseStatus status) {
    if (!engine.isHolding && !engine.isEnded) {
      _speakCalibrationIfChanged(status);
      return;
    }
    if (!_wasCalibratedOrReady && (engine.isHolding || engine.isEnded)) {
      _wasCalibratedOrReady = true;
      _lastCalibrationCategory = null;
      if (engine.isHolding) {
        _voice.speak("You're ready. Begin.", priority: VoicePriority.high);
      }
    }

    if (engine.isEnded) {
      _terminalAnnounced = true;
      _voice.speak('Test terminated.', priority: VoicePriority.high);
      return;
    }

    final wholeSeconds = engine.holdDuration.inSeconds;
    if (wholeSeconds > _lastPlankWholeSeconds) {
      _lastPlankWholeSeconds = wholeSeconds;
      if (wholeSeconds > 0) {
        _voice.speak('$wholeSeconds', priority: VoicePriority.medium);
      }
    }

    _handleWarning(engine.hasActiveFormWarning, engine.holdReason);
  }

  void _onVerticalJumpFrame(VerticalJumpEngine engine, ExerciseStatus status) {
    if (engine.isTestComplete) {
      _terminalAnnounced = true;
      _voice.speak('Test completed.', priority: VoicePriority.high);
      return;
    }

    if (!engine.isReadyToJump) {
      _wasCalibratedOrReady = false;
      _speakCalibrationIfChanged(status);
      return;
    }
    if (!_wasCalibratedOrReady) {
      _wasCalibratedOrReady = true;
      _lastCalibrationCategory = null;
      _voice.speak('You can jump now.', priority: VoicePriority.high);
    }

    if (engine.attempts.length > _lastRepOrAttemptCount) {
      _lastRepOrAttemptCount = engine.attempts.length;
      _voice.speak('$_lastRepOrAttemptCount', priority: VoicePriority.medium);
    }
    // No live mid-jump form-warning signal exists in VerticalJumpEngine
    // (attempt validity is only known retrospectively, after landing) -
    // see project report. Not inventing one here.
  }

  /// Speaks a form-warning correction (beep + short phrase) on the
  /// inactive->active transition, throttled by [_formWarningCooldown] for
  /// rapid reconfirm cycles. Resets on the active->inactive transition
  /// (warning cleared), per spec.
  void _handleWarning(bool isActive, String reasonText) {
    if (isActive && !_wasWarningActive) {
      final now = DateTime.now();
      final last = _lastWarningSpokenAt;
      if (last == null || now.difference(last) >= _formWarningCooldown) {
        _lastWarningSpokenAt = now;
        _voice.speakFormWarning(_shortFormCorrection(reasonText));
      }
    }
    _wasWarningActive = isActive;
  }

  /// Speaks a short mapped phrase for the current calibration/setup
  /// message, once per distinct category (not once per frame, and not on
  /// every percentage tick of an unchanged category). Uses the engine's
  /// own existing status text as input - never invents a new calibration
  /// condition.
  void _speakCalibrationIfChanged(ExerciseStatus status) {
    final category = _calibrationCategory(status.primaryText, status.secondaryText);
    if (category == null || category == _lastCalibrationCategory) return;
    _lastCalibrationCategory = category;
    _voice.speak(_calibrationPhraseFor(category), priority: VoicePriority.high);
  }

  /// Classifies the engine's current calibration text into a small,
  /// reusable bucket. Returns null for text not worth speaking (e.g.
  /// "body not detected", or a changing hold-still percentage - those
  /// already spoke "Hold still." once when that bucket was first entered).
  String? _calibrationCategory(String primaryText, String? secondaryText) {
    final combined = '$primaryText ${secondaryText ?? ''}';
    if (combined.contains('sideways')) return 'sideways';
    if (combined.contains('marked area') || combined.contains('facing the camera')) {
      return 'faceCamera';
    }
    if (combined.contains('Step back') || combined.contains('full body visible')) {
      return 'moveBack';
    }
    if (combined.contains('Return to the starting area')) return 'returnToStart';
    if (primaryText.startsWith('Hold still') || (secondaryText?.startsWith('Hold still') ?? false)) {
      return 'holdStill';
    }
    if (primaryText == 'Get into position') return 'getIntoPosition';
    return null;
  }

  String _calibrationPhraseFor(String category) => switch (category) {
    'sideways' => 'Stand sideways, get into position.',
    'faceCamera' => 'Stand facing the camera.',
    'moveBack' => 'Move back so your full body is visible.',
    'returnToStart' => 'Return to your starting position.',
    'holdStill' => 'Hold still.',
    'getIntoPosition' => 'Get into position.',
    _ => 'Get ready.',
  };

  /// Maps an existing form-check failure reason to a short spoken
  /// correction via keyword matching against the app's own real reason
  /// strings (see form_check.dart/plank_engine.dart) - not new
  /// biomechanics, just a shorter phrasing of what's already there.
  /// Falls back to a generic correction when the reason doesn't match a
  /// known keyword.
  String _shortFormCorrection(String reason) {
    final r = reason.toLowerCase();
    if (r.contains('sideways')) return 'Turn more sideways.';
    if (r.contains('arm') || r.contains('elbow')) return 'Keep your arms straight.';
    if (r.contains('leg') || r.contains('knee')) return 'Keep your legs straight.';
    if (r.contains('hip') || r.contains('straight') || r.contains('horizontal')) {
      return 'Keep your back straight.';
    }
    if (r.contains('torso') || r.contains('upright')) return 'Keep your torso upright.';
    if (r.contains('frame') || r.contains('visible')) return 'Move into frame.';
    return 'Correct your posture.';
  }

  /// Call when the athlete/operator stops the test manually. Only
  /// announces if the engine hasn't already reached a terminal state on
  /// its own this frame cycle (avoids double-announcing "test
  /// terminated"/"test completed" for the same test).
  void onStopPressed(ExerciseEngine engine) {
    if (!_supported || _terminalAnnounced) return;
    _terminalAnnounced = true;
    switch (_exerciseType) {
      case ExerciseType.pushUp:
        final e = engine as AngleCycleEngine;
        if (e.isTerminated) return; // already spoken via onFrame
        _voice.speak(
          'Test completed. You completed ${e.repCount} push-ups.',
          priority: VoicePriority.high,
        );
      case ExerciseType.plank:
        final e = engine as PlankEngine;
        if (e.isEnded) return; // already spoken via onFrame
        _voice.speak(
          'Test completed. You held for ${e.holdDuration.inSeconds} seconds.',
          priority: VoicePriority.high,
        );
      case ExerciseType.verticalJump:
        final e = engine as VerticalJumpEngine;
        if (e.isTestComplete) return; // already spoken via onFrame
        _voice.speak('Test cancelled.', priority: VoicePriority.high);
      default:
        break;
    }
  }
}
