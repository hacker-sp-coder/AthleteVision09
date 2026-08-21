import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import 'exercise_engine.dart';
import 'form_check.dart';
import 'pose_utils.dart';
import 'sided_pose.dart';

enum _WallSitState { setup, holding, ended }

/// Wall-sit isometric hold: side-on, knee angle held near 90 degrees for as
/// long as possible. Deliberately NOT built on `AngleCycleEngine` - that
/// engine's TOP/DESCENDING/BOTTOM/ASCENDING cycle exists to count discrete
/// reps, and a sustained hold has no "rep" to count, no return-to-top event,
/// and no natural mapping onto that FSM. This engine instead accumulates
/// elapsed valid-hold time directly, following the same dedicated-engine
/// precedent as [ExerciseEngine]'s other non-rep exercise (vertical jump).
///
/// Wall contact itself is a physical setup requirement stated in the UI
/// instructions - it is never inferred from pose landmarks.
class WallSitEngine extends ExerciseEngine {
  static const String setupInstruction =
      'Stand side-on with your back against a wall. Lower until your knees '
      'are around 90°. Cross your arms and hold.';

  /// Knee-angle band (hip-knee-ankle) counted as a valid wall-sit hold.
  /// Deliberately a wide band around the target 90 degrees, not a tight
  /// threshold, so ordinary ML Kit landmark jitter doesn't flicker the
  /// timer in and out of "valid" every frame.
  static const double _kMinKneeAngleDeg = 80;
  static const double _kMaxKneeAngleDeg = 100;

  /// How long a qualifying (side-on, in-range) pose must hold before the
  /// timer starts - mirrors the stability-window pattern used for
  /// calibration elsewhere in this codebase.
  static const Duration _kStabilityWindow = Duration(milliseconds: 1500);

  /// How long the pose must remain continuously invalid (out of angle
  /// range, no longer side-on, or not visible) before the hold is judged to
  /// have genuinely ended, as opposed to a brief wobble or landmark
  /// dropout. Deliberately much longer than a single-frame blip.
  static const Duration _kExitDebounce = Duration(milliseconds: 2000);

  /// Upper bound on the elapsed time credited for a single processed frame.
  /// Guards the hold-time accumulator against crediting an unrealistically
  /// large span (e.g. the detector stalling on one frame) as valid hold
  /// time once tracking resumes.
  static const Duration _kMaxFrameTick = Duration(milliseconds: 400);

  static const List<BodyPoint> _kRequiredPoints = [
    BodyPoint.shoulder,
    BodyPoint.hip,
    BodyPoint.knee,
    BodyPoint.ankle,
  ];

  /// Coarse visibility/orientation gate, reused as-is from the existing
  /// side-view exercises rather than reimplemented.
  static const List<FormCheck> _kPostureChecks = [
    RequiredLandmarksCheck(),
    SideOrientationCheck(),
  ];

  bool? _preferredSideIsLeft;
  _WallSitState _state = _WallSitState.setup;
  bool _isBodyVisible = false;

  DateTime? _stableSince;
  String _calibrationMessage = setupInstruction;

  DateTime? _lastTickTime;
  DateTime? _invalidSince;
  String _holdReason = '';

  Duration _totalValidDuration = Duration.zero;
  Duration _totalElapsedDuration = Duration.zero;
  Duration _currentStreak = Duration.zero;
  Duration _maxContinuousValidDuration = Duration.zero;

  @override
  void reset() {
    _preferredSideIsLeft = null;
    _state = _WallSitState.setup;
    _isBodyVisible = false;
    _stableSince = null;
    _calibrationMessage = setupInstruction;
    _lastTickTime = null;
    _invalidSince = null;
    _holdReason = '';
    _totalValidDuration = Duration.zero;
    _totalElapsedDuration = Duration.zero;
    _currentStreak = Duration.zero;
    _maxContinuousValidDuration = Duration.zero;
  }

  @override
  void processPose(Pose? pose) {
    // Ends only via the sustained-exit debounce below; a voluntary stop is
    // handled entirely by LiveTestScreen ending the camera stream, which
    // simply freezes this engine's last computed status on screen.
    if (_state == _WallSitState.ended) return;

    final now = DateTime.now();
    switch (_state) {
      case _WallSitState.setup:
        _processSetup(pose, now);
      case _WallSitState.holding:
        _processHolding(pose, now);
      case _WallSitState.ended:
        break;
    }
  }

  ({bool valid, String reason}) _evaluate(Pose? pose) {
    if (pose == null) {
      return (valid: false, reason: 'Body not detected');
    }

    final sidedPose = resolveSidedPose(
      pose,
      requiredPoints: _kRequiredPoints,
      confidenceThreshold: kMinLandmarkLikelihood,
      preferLeftSide: _preferredSideIsLeft,
    );
    if (sidedPose != null) _preferredSideIsLeft = sidedPose.isLeftSide;

    final context = FormCheckContext(pose: pose, sidedPose: sidedPose);
    for (final check in _kPostureChecks) {
      final result = check.evaluate(context);
      if (result.status != CheckStatus.valid) {
        return (valid: false, reason: result.reason);
      }
    }

    final hip = sidedPose![BodyPoint.hip];
    final knee = sidedPose[BodyPoint.knee];
    final ankle = sidedPose[BodyPoint.ankle];
    if (hip == null || knee == null || ankle == null) {
      return (valid: false, reason: 'Legs not fully visible');
    }

    final kneeAngle = angleBetweenPoints(hip, knee, ankle);
    if (kneeAngle > _kMaxKneeAngleDeg) {
      return (valid: false, reason: 'Lower into the wall-sit position - bend your knees more');
    }
    if (kneeAngle < _kMinKneeAngleDeg) {
      return (valid: false, reason: 'Come up slightly - knees are bent too far');
    }
    return (valid: true, reason: '');
  }

  void _processSetup(Pose? pose, DateTime now) {
    _isBodyVisible = pose != null;
    final result = _evaluate(pose);

    if (!result.valid) {
      _stableSince = null;
      _calibrationMessage = result.reason;
      return;
    }

    _stableSince ??= now;
    if (now.difference(_stableSince!) >= _kStabilityWindow) {
      _state = _WallSitState.holding;
      _lastTickTime = now;
      _totalValidDuration = Duration.zero;
      _totalElapsedDuration = Duration.zero;
      _currentStreak = Duration.zero;
      _maxContinuousValidDuration = Duration.zero;
      _invalidSince = null;
      _holdReason = '';
    }
  }

  void _processHolding(Pose? pose, DateTime now) {
    _isBodyVisible = pose != null;
    final result = _evaluate(pose);

    final rawDt = _lastTickTime != null ? now.difference(_lastTickTime!) : Duration.zero;
    final dt = rawDt > _kMaxFrameTick ? _kMaxFrameTick : rawDt;
    _lastTickTime = now;
    _totalElapsedDuration += dt;

    if (result.valid) {
      _invalidSince = null;
      _holdReason = '';
      _totalValidDuration += dt;
      _currentStreak += dt;
      if (_currentStreak > _maxContinuousValidDuration) {
        _maxContinuousValidDuration = _currentStreak;
      }
      return;
    }

    _currentStreak = Duration.zero;
    _holdReason = result.reason;
    _invalidSince ??= now;
    if (now.difference(_invalidSince!) >= _kExitDebounce) {
      _state = _WallSitState.ended;
    }
  }

  String _formatDuration(Duration d) => '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';

  @override
  ExerciseStatus get status {
    switch (_state) {
      case _WallSitState.setup:
        if (!_isBodyVisible) {
          return ExerciseStatus(
            primaryText: setupInstruction,
            secondaryText: 'Body not detected',
            isBodyVisible: false,
          );
        }
        if (_stableSince == null) {
          return ExerciseStatus(
            primaryText: 'Get into position',
            secondaryText: _calibrationMessage,
            isBodyVisible: true,
          );
        }
        final elapsedMs = DateTime.now().difference(_stableSince!).inMilliseconds;
        final pct = (elapsedMs / _kStabilityWindow.inMilliseconds * 100)
            .clamp(0, 100)
            .toStringAsFixed(0);
        return ExerciseStatus(
          primaryText: 'Hold still...',
          secondaryText: 'Confirming position ($pct%)',
          isBodyVisible: true,
        );

      case _WallSitState.holding:
        final secondary = _holdReason.isEmpty
            ? 'Holding - keep your knees near 90°'
            : 'Paused - $_holdReason';
        return ExerciseStatus(
          primaryText: 'Hold time: ${_formatDuration(_totalValidDuration)}',
          secondaryText: secondary,
          isBodyVisible: _isBodyVisible,
        );

      case _WallSitState.ended:
        final totalMs = _totalElapsedDuration.inMilliseconds;
        final pct = totalMs > 0
            ? (_totalValidDuration.inMilliseconds / totalMs * 100).toStringAsFixed(0)
            : '0';
        return ExerciseStatus(
          primaryText: 'Final hold time: ${_formatDuration(_totalValidDuration)}',
          secondaryText:
              'In range: $pct%   •   Best streak: ${_formatDuration(_maxContinuousValidDuration)}',
          isBodyVisible: _isBodyVisible,
        );
    }
  }
}
