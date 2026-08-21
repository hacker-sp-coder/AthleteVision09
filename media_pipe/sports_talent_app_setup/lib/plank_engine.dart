import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import 'exercise_engine.dart';
import 'form_check.dart';
import 'pose_utils.dart';
import 'sided_pose.dart';

enum _PlankState { setup, holding, ended }

/// Straight-arm plank hold: the same body configuration as a Push-up's TOP
/// position, held statically instead of cycled through reps. Deliberately
/// NOT built on `AngleCycleEngine` - that engine's rep-cycle FSM has no
/// concept of accumulated hold time, only TOP/DESCENDING/BOTTOM/ASCENDING
/// phase transitions and a rep count, and forcing a static hold through it
/// would be more fragile than a small dedicated engine. Follows the same
/// dedicated sustained-hold shape as `WallSitEngine`, but - unlike that
/// engine - reuses Push-up's own proven [FormCheck]s directly for posture
/// validity (see [_kPostureChecks]) rather than any new geometry: a plank
/// IS the push-up TOP position, so the same checks that already validate
/// that position for Push-up apply unchanged here.
///
/// Calibration mirrors `AngleCycleEngine`'s own stability-window +
/// reference-averaging algorithm (see [_buildReference]), since this engine
/// intentionally does not construct an `AngleCycleEngine` to get it for
/// free. Post-calibration form monitoring reuses the same
/// uncertain-frame-tolerance + sustained-invalid-confirmation two-layer
/// debounce `AngleCycleEngine` already uses to tell real ML Kit noise apart
/// from a genuine, sustained form break (see [_kMaxUncertainFrames] and
/// [_kInvalidConfirmationDuration], both reusing that engine's own default
/// values) - once confirmed, the hold ends outright rather than accumulating
/// warnings, since a single continuous hold (unlike a multi-rep set) has no
/// meaningful "next attempt" to keep going for.
class PlankEngine extends ExerciseEngine {
  static const String setupInstruction =
      'Turn sideways to the camera, keep your entire body visible, and get '
      'into the straight-arm push-up (plank) position - arms and legs '
      'extended, body straight. Hold as long as possible.';

  /// Same landmark set Push-up requires - nothing added, nothing removed.
  static const List<BodyPoint> _kRequiredPoints = [
    BodyPoint.shoulder,
    BodyPoint.elbow,
    BodyPoint.wrist,
    BodyPoint.hip,
    BodyPoint.knee,
    BodyPoint.ankle,
  ];

  /// Posture validity, reusing Push-up's own proven checks (see
  /// `pushUpExerciseConfig` in exercise_config.dart) with two deliberate
  /// differences, both additive/configurable rather than changes to Push-up
  /// itself:
  ///  - [LegExtensionCheck] is reused a second time, retargeted at the arm
  ///    (shoulder-elbow-wrist) via its new optional `key`/`checkName`/
  ///    `invalidReason` parameters, to enforce the straight-arm support
  ///    Push-up's own rep-cycle threshold (TOP >= 155 degrees) already
  ///    established as the correct value for "arms straight" in this app,
  ///    but which lives inside `AngleCycleEngine`'s phase logic rather than
  ///    as a reusable FormCheck. 155 degrees is that same proven value,
  ///    reused directly rather than invented; toleranceDeg reuses
  ///    `LegExtensionCheck`'s own existing default.
  ///  - Push-up's `AngleRangeCheck` (broad 50-180 degree elbow-angle
  ///    plausibility floor, meaningful only across a full rep's range of
  ///    motion) is intentionally omitted: the arm-extension check above is
  ///    already strictly tighter for a static hold, so it would never fire.
  static const List<FormCheck> _kPostureChecks = [
    RequiredLandmarksCheck(),
    SideOrientationCheck(),
    BodyInclinationCheck(
      from: BodyPoint.shoulder,
      to: BodyPoint.ankle,
      maxInclinationFromHorizontalDeg: 40,
      invalidReason: 'Get into a horizontal plank position - straight line from shoulders to ankles',
    ),
    BodyRigidityCheck(
      a: BodyPoint.shoulder,
      b: BodyPoint.hip,
      c: BodyPoint.ankle,
      absoluteMinDeg: 155,
      toleranceDeg: 18,
    ),
    LegExtensionCheck(),
    LegExtensionCheck(
      a: BodyPoint.shoulder,
      b: BodyPoint.elbow,
      c: BodyPoint.wrist,
      absoluteMinDeg: 155,
      toleranceDeg: 20,
      key: 'armExtensionAngleDeg',
      checkName: 'arm_extension',
      notVisibleReason: 'Arms not visible',
      invalidReason: 'Keep your arms straight - do not bend your elbows',
    ),
  ];

  /// How long a qualifying pose must hold before the timer starts - the
  /// exact same default `ExerciseConfig.stabilityWindow` (and therefore
  /// Push-up itself) uses.
  static const Duration _kStabilityWindow = Duration(milliseconds: 1500);

  /// Consecutive UNCERTAIN frames tolerated before treating the pose as a
  /// real (not just momentarily noisy) problem - reuses
  /// `ExerciseConfig.maxUncertainFrames`'s own default value/purpose.
  static const int _kMaxUncertainFrames = 5;

  /// How long a definite invalid/escalated-uncertain status must persist
  /// continuously before the hold is confirmed over - reuses
  /// `ExerciseConfig.sustainedInvalidConfirmation`'s own default
  /// value/purpose (the same debounce Push-up itself uses to tell a brief
  /// blip apart from a real, sustained form break).
  static const Duration _kInvalidConfirmationDuration = Duration(milliseconds: 800);

  /// Upper bound on the elapsed time credited for a single processed frame,
  /// guarding the hold-time accumulator against crediting an unrealistic
  /// span (e.g. a stalled detector) as valid hold time once tracking
  /// resumes.
  static const Duration _kMaxFrameTick = Duration(milliseconds: 400);

  bool? _preferredSideIsLeft;
  _PlankState _state = _PlankState.setup;
  bool _isBodyVisible = false;

  DateTime? _stableSince;
  final List<FormCheckContext> _stabilitySamples = [];
  String _calibrationMessage = setupInstruction;
  ExerciseReference? _reference;

  DateTime? _lastTickTime;
  int _consecutiveUncertain = 0;
  DateTime? _invalidSince;
  String _holdReason = '';
  Duration _totalValidDuration = Duration.zero;

  @override
  void reset() {
    _preferredSideIsLeft = null;
    _state = _PlankState.setup;
    _isBodyVisible = false;
    _stableSince = null;
    _stabilitySamples.clear();
    _calibrationMessage = setupInstruction;
    _reference = null;
    _lastTickTime = null;
    _consecutiveUncertain = 0;
    _invalidSince = null;
    _holdReason = '';
    _totalValidDuration = Duration.zero;
  }

  @override
  void processPose(Pose? pose) {
    if (_state == _PlankState.ended) return;

    final now = DateTime.now();
    switch (_state) {
      case _PlankState.setup:
        _processSetup(pose, now);
      case _PlankState.holding:
        _processHolding(pose, now);
      case _PlankState.ended:
        break;
    }
  }

  ({CheckStatus status, String reason, FormCheckContext? context}) _evaluate(
    Pose? pose, {
    required bool useCalibratedReference,
  }) {
    if (pose == null) {
      return (status: CheckStatus.uncertain, reason: 'Body not detected', context: null);
    }

    final sidedPose = resolveSidedPose(
      pose,
      requiredPoints: _kRequiredPoints,
      confidenceThreshold: kMinLandmarkLikelihood,
      preferLeftSide: _preferredSideIsLeft,
    );
    if (sidedPose != null) _preferredSideIsLeft = sidedPose.isLeftSide;

    final context = FormCheckContext(
      pose: pose,
      sidedPose: sidedPose,
      reference: useCalibratedReference ? _reference : null,
    );
    for (final check in _kPostureChecks) {
      final result = check.evaluate(context);
      if (result.status != CheckStatus.valid) {
        return (status: result.status, reason: result.reason, context: context);
      }
    }
    return (status: CheckStatus.valid, reason: '', context: context);
  }

  /// Mirrors `AngleCycleEngine._buildReference`: averages each check's
  /// sampled value across the stability window into one calibrated
  /// baseline per reference key.
  ExerciseReference _buildReference(List<FormCheckContext> samples) {
    final values = <String, double>{};
    for (final check in _kPostureChecks) {
      final key = check.referenceKey;
      if (key == null) continue;
      final samplesForCheck = samples.map(check.sampleValue).whereType<double>().toList();
      if (samplesForCheck.isEmpty) continue;
      values[key] = samplesForCheck.reduce((a, b) => a + b) / samplesForCheck.length;
    }
    return ExerciseReference(values);
  }

  void _processSetup(Pose? pose, DateTime now) {
    _isBodyVisible = pose != null;
    final result = _evaluate(pose, useCalibratedReference: false);

    if (result.status != CheckStatus.valid) {
      _stableSince = null;
      _stabilitySamples.clear();
      _calibrationMessage = result.reason.isEmpty ? setupInstruction : result.reason;
      return;
    }

    _stableSince ??= now;
    _stabilitySamples.add(result.context!);
    final elapsed = now.difference(_stableSince!);

    if (elapsed >= _kStabilityWindow) {
      _reference = _buildReference(_stabilitySamples);
      _state = _PlankState.holding;
      _lastTickTime = now;
      _consecutiveUncertain = 0;
      _invalidSince = null;
      _holdReason = '';
      _totalValidDuration = Duration.zero;
      return;
    }

    final pct = (elapsed.inMilliseconds / _kStabilityWindow.inMilliseconds * 100)
        .clamp(0, 100)
        .toStringAsFixed(0);
    _calibrationMessage = 'Hold still... $pct%';
  }

  void _processHolding(Pose? pose, DateTime now) {
    _isBodyVisible = pose != null;
    final result = _evaluate(pose, useCalibratedReference: true);

    final rawDt = _lastTickTime != null ? now.difference(_lastTickTime!) : Duration.zero;
    final dt = rawDt > _kMaxFrameTick ? _kMaxFrameTick : rawDt;
    _lastTickTime = now;

    switch (result.status) {
      case CheckStatus.valid:
        _consecutiveUncertain = 0;
        _invalidSince = null;
        _holdReason = '';
        _totalValidDuration += dt;
      case CheckStatus.uncertain:
        _consecutiveUncertain++;
        _holdReason = result.reason;
        if (_consecutiveUncertain > _kMaxUncertainFrames) {
          _confirmInvalid(now);
        }
      case CheckStatus.invalid:
        _consecutiveUncertain = 0;
        _holdReason = result.reason;
        _confirmInvalid(now);
    }
  }

  void _confirmInvalid(DateTime now) {
    _invalidSince ??= now;
    if (now.difference(_invalidSince!) >= _kInvalidConfirmationDuration) {
      _state = _PlankState.ended;
    }
  }

  String _formatDuration(Duration d) => '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';

  @override
  ExerciseStatus get status {
    switch (_state) {
      case _PlankState.setup:
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
        return ExerciseStatus(
          primaryText: 'Hold still...',
          secondaryText: _calibrationMessage,
          isBodyVisible: true,
        );

      case _PlankState.holding:
        final secondary =
            _holdReason.isEmpty ? 'Holding - keep your body straight' : 'Form: $_holdReason';
        return ExerciseStatus(
          primaryText: 'Plank Hold: ${_formatDuration(_totalValidDuration)}',
          secondaryText: secondary,
          isBodyVisible: _isBodyVisible,
        );

      case _PlankState.ended:
        return ExerciseStatus(
          primaryText: 'Plank Hold: ${_formatDuration(_totalValidDuration)}',
          secondaryText: _holdReason.isEmpty ? 'Test ended' : 'Ended - $_holdReason',
          isBodyVisible: _isBodyVisible,
        );
    }
  }
}
