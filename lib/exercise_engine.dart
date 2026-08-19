import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import 'pose_utils.dart';

enum ExerciseType { verticalJump, pushUp, squat }

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
  /// the engine doesn't use one. Engines that don't need one inherit this
  /// harmless default.
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
