import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// How urgently a spoken item should be delivered. See [VoiceFeedbackService].
enum VoicePriority {
  /// Calibration/setup instructions, ready-to-start cues, test
  /// completion/termination/cancellation. Interrupts anything currently
  /// speaking and jumps the queue.
  high,

  /// Rep numbers, plank elapsed seconds.
  medium,

  /// Short form-correction phrases, spoken alongside a beep. Throttled by
  /// the caller (see ExerciseVoiceCoach) - this service just queues them.
  formWarning,
}

/// Centralized on-device voice-coaching output: offline TTS for short
/// spoken phrases, plus a short system beep for form warnings. No network/
/// cloud dependency - flutter_tts wraps the platform's built-in TTS engine
/// (Android TextToSpeech / iOS AVSpeechSynthesizer), and the beep uses
/// Flutter's built-in system sound, so nothing here calls out to the
/// internet.
///
/// A simple FIFO queue with one interrupt rule keeps things reliable
/// without overengineering: HIGH priority items clear any queued
/// medium/form-warning items and stop whatever is currently speaking, so
/// important cues (e.g. "You can jump now.") are never buried behind a
/// backlog of rep numbers. Medium/form-warning items are capped so a
/// slow-to-speak run of numbers can't drift far behind real time.
class VoiceFeedbackService {
  VoiceFeedbackService() {
    unawaited(_configure());
  }

  late final FlutterTts _tts = FlutterTts();
  final List<_QueueItem> _queue = [];
  bool _speaking = false;
  bool _disposed = false;

  static const int _maxBacklogPerNonHighPriority = 2;

  Future<void> _configure() async {
    try {
      await _tts.setLanguage('en-US');
      await _tts.setSpeechRate(0.5);
      await _tts.setVolume(1.0);
      await _tts.awaitSpeakCompletion(true);
    } catch (_) {
      // On-device TTS voice/language pack may be unavailable on some
      // devices - voice coaching becomes a silent no-op rather than a
      // crash; the rest of the test is unaffected.
    }
  }

  /// Queues [text] to be spoken. See [VoicePriority] for ordering/
  /// interrupt behavior.
  void speak(String text, {VoicePriority priority = VoicePriority.medium}) {
    if (_disposed || text.isEmpty) return;

    if (priority == VoicePriority.high) {
      _queue.removeWhere((item) => item.priority != VoicePriority.high);
      _queue.insert(0, _QueueItem(text, priority));
      if (_speaking) {
        unawaited(_tts.stop());
      }
    } else {
      final backlog = _queue.where((item) => item.priority == priority).length;
      if (backlog >= _maxBacklogPerNonHighPriority) {
        final idx = _queue.indexWhere((item) => item.priority == priority);
        if (idx != -1) _queue.removeAt(idx);
      }
      _queue.add(_QueueItem(text, priority));
    }
    unawaited(_pump());
  }

  /// Short, distinctive alert for form warnings - a built-in system sound,
  /// not a bundled audio asset, so no extra dependency/asset is needed for
  /// this V1.
  void beep() {
    if (_disposed) return;
    unawaited(SystemSound.play(SystemSoundType.alert));
  }

  /// Convenience for the common "beep then say the correction" pairing
  /// used for form warnings.
  void speakFormWarning(String text) {
    beep();
    speak(text, priority: VoicePriority.formWarning);
  }

  Future<void> _pump() async {
    if (_speaking || _disposed) return;
    if (_queue.isEmpty) return;
    _speaking = true;
    final item = _queue.removeAt(0);
    try {
      await _tts.speak(item.text);
    } catch (_) {
      // Swallow - a failed utterance shouldn't break the queue or the test.
    }
    _speaking = false;
    if (!_disposed && _queue.isNotEmpty) {
      unawaited(_pump());
    }
  }

  /// Clears any pending speech and stops the current utterance - used
  /// when a test ends, so nothing queued from one test bleeds into the
  /// next.
  void stop() {
    _queue.clear();
    unawaited(_tts.stop());
    _speaking = false;
  }

  void dispose() {
    _disposed = true;
    _queue.clear();
    unawaited(_tts.stop());
  }
}

class _QueueItem {
  _QueueItem(this.text, this.priority);
  final String text;
  final VoicePriority priority;
}
