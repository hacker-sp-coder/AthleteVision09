import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import 'pose_utils.dart';
import 'push_up_form_validator.dart';

enum ExerciseType { verticalJump, pushUp }

class ExerciseStatus {
  const ExerciseStatus({
    required this.primaryText,
    this.secondaryText,
    required this.isBodyVisible,
  });

  final String primaryText;
  final String? secondaryText;
  final bool isBodyVisible;
}

abstract class ExerciseEngine {
  ExerciseStatus get status;

  void reset();

  void processPose(Pose? pose);

  /// Raw image-space Y of an adaptive on-screen reference guide, or null if
  /// the engine doesn't use one. Overridden by [PushUpEngine] during
  /// calibration; other engines inherit this harmless default.
  double? get groundGuideImageY => null;
}

class VerticalJumpEngine extends ExerciseEngine {
  VerticalJumpEngine({required this.userHeightCm});

  final double userHeightCm;

  static const int kBaselineFrameCount = 15;
  static const double kEmaAlpha = 0.5;

  double? _cmPerPixel;
  double? _smoothedHipY;
  double? _baselineHipY;
  final List<double> _baselineSamples = [];
  bool _calibrated = false;
  bool _isBodyVisible = false;
  double _currentJumpHeightCm = 0;
  double _bestJumpHeightCm = 0;

  @override
  void reset() {
    _cmPerPixel = null;
    _smoothedHipY = null;
    _baselineHipY = null;
    _baselineSamples.clear();
    _calibrated = false;
    _isBodyVisible = false;
    _currentJumpHeightCm = 0;
    _bestJumpHeightCm = 0;
  }

  @override
  void processPose(Pose? pose) {
    _isBodyVisible = pose != null && isFullBodyVisible(pose);
    if (!_isBodyVisible || pose == null) return;

    final hipY = averageHipY(pose);
    if (hipY == null) return;

    _smoothedHipY = _smoothedHipY == null
        ? hipY
        : kEmaAlpha * hipY + (1 - kEmaAlpha) * _smoothedHipY!;

    if (!_calibrated) {
      _cmPerPixel ??= () {
        final heightPx = estimateStandingHeightPixels(pose);
        if (heightPx == null || heightPx <= 0) return null;
        return cmPerPixel(heightPx, userHeightCm);
      }();

      _baselineSamples.add(_smoothedHipY!);

      if (_baselineSamples.length >= kBaselineFrameCount && _cmPerPixel != null) {
        _baselineHipY =
            _baselineSamples.reduce((a, b) => a + b) / _baselineSamples.length;
        _calibrated = true;
      }
      return;
    }

    final displacementPx = _baselineHipY! - _smoothedHipY!;
    if (displacementPx > 0) {
      final heightCm = displacementPx * _cmPerPixel!;
      _currentJumpHeightCm = heightCm;
      if (heightCm > _bestJumpHeightCm) {
        _bestJumpHeightCm = heightCm;
      }
    } else {
      _currentJumpHeightCm = 0;
    }
  }

  @override
  ExerciseStatus get status {
    if (!_calibrated) {
      return ExerciseStatus(
        primaryText:
            'Calibrating... stand still (${_baselineSamples.length}/$kBaselineFrameCount)',
        isBodyVisible: _isBodyVisible,
      );
    }
    return ExerciseStatus(
      primaryText: 'Best Jump: ${_bestJumpHeightCm.toStringAsFixed(1)} cm',
      secondaryText: 'Current: ${_currentJumpHeightCm.toStringAsFixed(1)} cm',
      isBodyVisible: _isBodyVisible,
    );
  }
}

const String kPushUpSetupInstruction =
    'Turn sideways to the camera, keep your entire body visible, and get '
    'into the starting push-up position.';

enum PushUpCalibrationStage {
  setup,
  sideViewValid,
  fullBodyValid,
  gettingIntoPosition,
  topDetected,
  holdSteady,
  calibrated,
}

/// A Continuous Push-up Form Integrity System: calibration establishes an
/// athlete-specific valid-TOP reference envelope (see
/// [PushUpFormValidator]/[PushUpReferenceModel]), and every pose after that
/// is continuously re-validated against it. Rep counting is intentionally
/// NOT implemented yet - this only builds the calibration + continuous
/// validation foundation a future rep state machine will be gated by.
class PushUpEngine extends ExerciseEngine {
  static const double kEmaAlpha = 0.4;
  static const Duration kStabilityWindow = Duration(milliseconds: 1500);

  // Consecutive frames required before a *displayed* calibration stage
  // change commits, separate from the stability window above - avoids
  // flicker right at the landmark-likelihood boundary. The final
  // topDetected/holdSteady/calibrated transitions bypass this since the
  // stability window already debounces them robustly.
  static const int kStageDebounceFrames = 3;

  // sideOnRatio is null whenever the far shoulder is momentarily occluded -
  // which is the *common* case in good side-on form, not an edge case. Hold
  // the last known-good value through a short run of null frames rather
  // than treating every occlusion blip as "not side-on".
  static const int kSideOnHoldFrames = 5;

  // Asymmetric on purpose: "false positives worse than false negatives"
  // means lean slower to confirm VALID, quicker to flag a problem.
  static const int kValidDebounceFrames = 3;
  static const int kInvalidDebounceFrames = 2;

  bool? _preferredSideIsLeft;

  double? _heldSideOnRatio;
  int _sideOnNullStreak = 0;

  PushUpPoseMetrics? _smoothed;

  PushUpCalibrationStage _stage = PushUpCalibrationStage.setup;
  PushUpCalibrationStage? _pendingStage;
  int _pendingStageStreak = 0;
  String _calibrationMessage = kPushUpSetupInstruction;

  DateTime? _stableSince;
  final List<PushUpPoseMetrics> _stabilitySamples = [];
  PushUpReferenceModel? _reference;

  bool _isBodyVisible = false;
  double? _groundGuideImageY;

  FormStatus _formStatus = FormStatus.uncertain;
  String _formReason = '';
  int _consecutiveValid = 0;
  int _consecutiveInvalid = 0;

  bool get _calibrated => _stage == PushUpCalibrationStage.calibrated;

  @override
  void reset() {
    _preferredSideIsLeft = null;
    _heldSideOnRatio = null;
    _sideOnNullStreak = 0;
    _smoothed = null;
    _stage = PushUpCalibrationStage.setup;
    _pendingStage = null;
    _pendingStageStreak = 0;
    _calibrationMessage = kPushUpSetupInstruction;
    _stableSince = null;
    _stabilitySamples.clear();
    _reference = null;
    _isBodyVisible = false;
    _groundGuideImageY = null;
    _formStatus = FormStatus.uncertain;
    _formReason = '';
    _consecutiveValid = 0;
    _consecutiveInvalid = 0;
  }

  @override
  double? get groundGuideImageY => _calibrated ? null : _groundGuideImageY;

  /// Holds the last known-good smoothed sideOnRatio through short null
  /// streaks (occluded far shoulder), only actually going null after a
  /// sustained streak.
  double? _updateSideOnRatio(double? raw) {
    if (raw != null) {
      _sideOnNullStreak = 0;
      _heldSideOnRatio = _heldSideOnRatio == null
          ? raw
          : kEmaAlpha * raw + (1 - kEmaAlpha) * _heldSideOnRatio!;
      return _heldSideOnRatio;
    }
    _sideOnNullStreak++;
    if (_sideOnNullStreak > kSideOnHoldFrames) {
      _heldSideOnRatio = null;
      return null;
    }
    return _heldSideOnRatio;
  }

  /// Smooths raw metrics (EMA on numeric fields + held sideOnRatio) and
  /// updates side-selection stickiness. Shared by calibration and tracking.
  PushUpPoseMetrics _smoothMetrics(PushUpPoseMetrics rawMetrics) {
    _preferredSideIsLeft = rawMetrics.isLeftSide;
    _groundGuideImageY = rawMetrics.groundGuideImageY;
    final blended = rawMetrics.smoothedTowards(_smoothed, kEmaAlpha);
    final heldSideOn = _updateSideOnRatio(rawMetrics.sideOnRatio);
    _smoothed = blended.withSideOnRatio(heldSideOn);
    return _smoothed!;
  }

  void _resetStability() {
    _stableSince = null;
    _stabilitySamples.clear();
  }

  void _setStage(PushUpCalibrationStage stage, String message) {
    _calibrationMessage = message; // updates every frame for responsiveness
    if (stage == _pendingStage) {
      _pendingStageStreak++;
    } else {
      _pendingStage = stage;
      _pendingStageStreak = 1;
    }
    final bypassDebounce = stage == PushUpCalibrationStage.topDetected ||
        stage == PushUpCalibrationStage.holdSteady ||
        stage == PushUpCalibrationStage.calibrated;
    if (bypassDebounce || _pendingStageStreak >= kStageDebounceFrames) {
      _stage = stage;
    }
  }

  void _registerValid(String reason) {
    _consecutiveInvalid = 0;
    _consecutiveValid++;
    if (_consecutiveValid >= kValidDebounceFrames) {
      _formStatus = FormStatus.valid;
      _formReason = reason;
    }
  }

  void _registerNonValid(FormStatus status, String reason) {
    _consecutiveValid = 0;
    _consecutiveInvalid++;
    if (_consecutiveInvalid >= kInvalidDebounceFrames) {
      _formStatus = status;
      _formReason = reason;
    }
  }

  @override
  void processPose(Pose? pose) {
    if (pose == null) {
      _isBodyVisible = false;
      if (!_calibrated) {
        _setStage(PushUpCalibrationStage.setup, kPushUpSetupInstruction);
        _resetStability();
      } else {
        _registerNonValid(FormStatus.uncertain, 'Body not detected');
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
    final lightRatio = PushUpFormValidator.lightSideOnCheck(pose);
    if (lightRatio == null) {
      _setStage(
        PushUpCalibrationStage.setup,
        'Move into frame so your upper body is visible',
      );
      _resetStability();
      return;
    }
    if (lightRatio > kMaxSideOnShoulderRatio) {
      _setStage(PushUpCalibrationStage.setup, 'Turn sideways to the camera');
      _resetStability();
      return;
    }

    final rawMetrics =
        PushUpFormValidator.computeMetrics(pose, preferLeftSide: _preferredSideIsLeft);
    if (rawMetrics == null) {
      _setStage(
        PushUpCalibrationStage.sideViewValid,
        'Keep your entire body visible: shoulder to ankle',
      );
      _resetStability();
      _smoothed = null;
      return;
    }

    final metrics = _smoothMetrics(rawMetrics);
    final result = PushUpFormValidator.evaluateTopCandidate(metrics);

    if (result.status == FormStatus.valid) {
      final isFirstFrameOfStreak = _stableSince == null;
      _stableSince ??= DateTime.now();
      _stabilitySamples.add(metrics);
      final elapsed = DateTime.now().difference(_stableSince!);

      if (elapsed >= kStabilityWindow) {
        _reference = PushUpFormValidator.buildReferenceModel(_stabilitySamples);
        _setStage(PushUpCalibrationStage.calibrated, 'Starting position locked');
      } else if (isFirstFrameOfStreak) {
        _setStage(
          PushUpCalibrationStage.topDetected,
          'Valid position detected - hold still...',
        );
      } else {
        final pct = (elapsed.inMilliseconds / kStabilityWindow.inMilliseconds * 100)
            .clamp(0, 100)
            .toStringAsFixed(0);
        _setStage(PushUpCalibrationStage.holdSteady, 'Hold still... $pct%');
      }
      return;
    }

    _resetStability();

    const orientationViolations = {
      FormViolation.tooUpright,
      FormViolation.groundReferenceInvalid,
      FormViolation.notSideOn,
    };
    if (orientationViolations.contains(result.violation)) {
      _setStage(PushUpCalibrationStage.fullBodyValid, result.reason);
    } else {
      _setStage(PushUpCalibrationStage.gettingIntoPosition, result.reason);
    }
  }

  void _processTrackingFrame(Pose pose) {
    final rawMetrics =
        PushUpFormValidator.computeMetrics(pose, preferLeftSide: _preferredSideIsLeft);
    if (rawMetrics == null) {
      _registerNonValid(FormStatus.uncertain, 'Lost tracking - keep your full body in frame');
      return;
    }

    final metrics = _smoothMetrics(rawMetrics);
    final result = PushUpFormValidator.evaluateAgainstReference(metrics, _reference!);

    if (result.status == FormStatus.valid) {
      _registerValid(result.reason);
    } else {
      _registerNonValid(result.status, result.reason);
    }
  }

  String get _calibrationStageLabel {
    switch (_stage) {
      case PushUpCalibrationStage.setup:
        return 'Set up';
      case PushUpCalibrationStage.sideViewValid:
        return 'Side view OK';
      case PushUpCalibrationStage.fullBodyValid:
        return 'Body visible';
      case PushUpCalibrationStage.gettingIntoPosition:
        return 'Get into position';
      case PushUpCalibrationStage.topDetected:
      case PushUpCalibrationStage.holdSteady:
        return 'Hold steady';
      case PushUpCalibrationStage.calibrated:
        return 'Calibrated';
    }
  }

  @override
  ExerciseStatus get status {
    if (!_isBodyVisible) {
      return const ExerciseStatus(
        primaryText: kPushUpSetupInstruction,
        secondaryText: 'Body not detected',
        isBodyVisible: false,
      );
    }

    if (!_calibrated) {
      return ExerciseStatus(
        primaryText: _calibrationStageLabel,
        secondaryText: _calibrationMessage,
        isBodyVisible: true,
      );
    }

    return ExerciseStatus(
      primaryText: 'Form: ${_formStatus.name.toUpperCase()}',
      secondaryText: _formReason.isEmpty ? null : _formReason,
      isBodyVisible: true,
    );
  }
}
