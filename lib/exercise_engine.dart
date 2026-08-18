import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import 'pose_utils.dart';

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

enum _PushUpPhase { top, bottom }

class PushUpEngine extends ExerciseEngine {
  static const double kTopAngleThreshold = 160;
  static const double kBottomAngleThreshold = 90;
  static const Duration kMinRepInterval = Duration(milliseconds: 400);

  _PushUpPhase _phase = _PushUpPhase.top;
  int _repCount = 0;
  double? _lastElbowAngle;
  DateTime? _lastRepTime;
  bool _isBodyVisible = false;

  @override
  void reset() {
    _phase = _PushUpPhase.top;
    _repCount = 0;
    _lastElbowAngle = null;
    _lastRepTime = null;
    _isBodyVisible = false;
  }

  double? _sideAngle(
    Pose pose,
    PoseLandmarkType shoulder,
    PoseLandmarkType elbow,
    PoseLandmarkType wrist,
  ) {
    final s = pose.landmarks[shoulder];
    final e = pose.landmarks[elbow];
    final w = pose.landmarks[wrist];
    if (!isLandmarkVisible(s) || !isLandmarkVisible(e) || !isLandmarkVisible(w)) {
      return null;
    }
    return angleBetweenPoints(s!, e!, w!);
  }

  double? _computeElbowAngle(Pose pose) {
    final left = _sideAngle(
      pose,
      PoseLandmarkType.leftShoulder,
      PoseLandmarkType.leftElbow,
      PoseLandmarkType.leftWrist,
    );
    final right = _sideAngle(
      pose,
      PoseLandmarkType.rightShoulder,
      PoseLandmarkType.rightElbow,
      PoseLandmarkType.rightWrist,
    );
    if (left != null && right != null) return (left + right) / 2;
    return left ?? right;
  }

  @override
  void processPose(Pose? pose) {
    if (pose == null) {
      _isBodyVisible = false;
      return;
    }

    final angle = _computeElbowAngle(pose);
    _isBodyVisible = angle != null;
    if (angle == null) return;

    _lastElbowAngle = angle;

    if (_phase == _PushUpPhase.top && angle <= kBottomAngleThreshold) {
      _phase = _PushUpPhase.bottom;
    } else if (_phase == _PushUpPhase.bottom && angle >= kTopAngleThreshold) {
      final now = DateTime.now();
      if (_lastRepTime == null || now.difference(_lastRepTime!) >= kMinRepInterval) {
        _repCount++;
        _lastRepTime = now;
      }
      _phase = _PushUpPhase.top;
    }
  }

  @override
  ExerciseStatus get status {
    return ExerciseStatus(
      primaryText: 'Reps: $_repCount',
      secondaryText: _lastElbowAngle != null
          ? 'Elbow angle: ${_lastElbowAngle!.toStringAsFixed(0)}°'
          : 'Position yourself in frame',
      isBodyVisible: _isBodyVisible,
    );
  }
}
