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

const String kPushUpSetupInstruction =
    'Turn sideways to the camera, keep your entire body visible, and get '
    'into the starting push-up position.';

/// One side (left or right) of the body's push-up-relevant landmarks,
/// selected because it's the side facing the camera in a side-on view.
class _SidePose {
  const _SidePose({
    required this.shoulder,
    required this.elbow,
    required this.wrist,
    required this.hip,
    required this.knee,
    required this.ankle,
    required this.otherShoulder,
  });

  final PoseLandmark shoulder;
  final PoseLandmark elbow;
  final PoseLandmark wrist;
  final PoseLandmark hip;
  final PoseLandmark knee;
  final PoseLandmark ankle;

  /// The opposite shoulder, used only to judge how side-on the user is.
  /// May be missing/unreliable if heavily occluded, hence nullable.
  final PoseLandmark? otherShoulder;
}

enum _PushUpPhase { top, descending, bottom, ascending }

/// Counts push-up reps from a side-on view using body (shoulder/hip)
/// displacement as the primary signal and elbow angle only as a secondary
/// validation check, so bending the elbows in place without moving the body
/// does not register as a rep. See individual constants below for the
/// specific tunable thresholds.
class PushUpEngine extends ExerciseEngine {
  // --- Calibration ---
  // Consecutive good frames (correct side-on form, arms extended) required
  // before the TOP position is locked in and rep tracking begins.
  static const int kCalibrationFrameCount = 12;
  // Max ratio of on-screen shoulder-to-shoulder width to shoulder-to-hip
  // (torso) length allowed to count the user as "sufficiently side-on" -
  // in a true side view the shoulders should nearly overlap on screen.
  static const double kMaxSideOnShoulderRatio = 0.55;
  // Minimum shoulder-hip-ankle angle (degrees; 180 = perfectly straight)
  // to count the body as "reasonably straight", not a mathematically
  // perfect plank.
  static const double kMinBodyAlignmentAngle = 150;
  // Likelihood floor used only for the (possibly partially occluded) far
  // shoulder when judging side-on-ness - deliberately looser than the
  // strict per-landmark visibility threshold used everywhere else.
  static const double kMinPositionLikelihood = 0.3;

  // --- Movement tracking ---
  // EMA smoothing factor applied to the shoulder/hip midpoint Y position to
  // reduce ML Kit jitter before it's used for phase transitions.
  static const double kEmaAlpha = 0.4;
  // Downward displacement of the smoothed shoulder/hip midpoint, as a
  // fraction of the calibrated torso (shoulder-hip) length, required to
  // count as having reached the bottom region.
  static const double kDownDisplacementThreshold = 0.35;
  // Displacement (same units) the body must return within to count as back
  // at the top. Kept well below kDownDisplacementThreshold so the gap
  // between the two forms a hysteresis band that resists jitter.
  static const double kTopDisplacementThreshold = 0.12;

  // --- Elbow angle: secondary validation only, never the primary signal ---
  static const double kBottomElbowAngleMax = 130;
  static const double kTopElbowAngleMin = 150;

  // --- Debounce ---
  static const Duration kMinRepInterval = Duration(milliseconds: 600);

  bool _calibrated = false;
  int _calibrationStreak = 0;
  final List<double> _calibrationBodyY = [];
  final List<double> _calibrationScale = [];

  double? _topBodyY;
  double? _bodyScalePx;
  double? _smoothedBodyY;

  _PushUpPhase _phase = _PushUpPhase.top;
  int _repCount = 0;
  DateTime? _lastRepTime;

  bool _isBodyVisible = false;
  bool _formOk = false;
  double? _lastElbowAngle;

  @override
  void reset() {
    _calibrated = false;
    _calibrationStreak = 0;
    _calibrationBodyY.clear();
    _calibrationScale.clear();
    _topBodyY = null;
    _bodyScalePx = null;
    _smoothedBodyY = null;
    _phase = _PushUpPhase.top;
    _repCount = 0;
    _lastRepTime = null;
    _isBodyVisible = false;
    _formOk = false;
    _lastElbowAngle = null;
  }

  _SidePose? _extractSide(Pose pose, bool left) {
    final shoulder = pose.landmarks[
        left ? PoseLandmarkType.leftShoulder : PoseLandmarkType.rightShoulder];
    final elbow = pose.landmarks[
        left ? PoseLandmarkType.leftElbow : PoseLandmarkType.rightElbow];
    final wrist = pose.landmarks[
        left ? PoseLandmarkType.leftWrist : PoseLandmarkType.rightWrist];
    final hip =
        pose.landmarks[left ? PoseLandmarkType.leftHip : PoseLandmarkType.rightHip];
    final knee = pose
        .landmarks[left ? PoseLandmarkType.leftKnee : PoseLandmarkType.rightKnee];
    final ankle = pose.landmarks[
        left ? PoseLandmarkType.leftAnkle : PoseLandmarkType.rightAnkle];
    final otherShoulder = pose.landmarks[
        left ? PoseLandmarkType.rightShoulder : PoseLandmarkType.leftShoulder];

    if (!isLandmarkVisible(shoulder) ||
        !isLandmarkVisible(elbow) ||
        !isLandmarkVisible(wrist) ||
        !isLandmarkVisible(hip) ||
        !isLandmarkVisible(knee) ||
        !isLandmarkVisible(ankle)) {
      return null;
    }

    return _SidePose(
      shoulder: shoulder!,
      elbow: elbow!,
      wrist: wrist!,
      hip: hip!,
      knee: knee!,
      ankle: ankle!,
      otherShoulder: otherShoulder,
    );
  }

  /// Picks whichever side (left/right) has all six required landmarks
  /// confidently visible - the side facing the camera in a side-on stance.
  /// If both sides qualify, picks the more confident one.
  _SidePose? _selectSide(Pose pose) {
    final left = _extractSide(pose, true);
    final right = _extractSide(pose, false);
    if (left != null && right == null) return left;
    if (right != null && left == null) return right;
    if (left != null && right != null) {
      final leftScore = left.shoulder.likelihood + left.hip.likelihood;
      final rightScore = right.shoulder.likelihood + right.hip.likelihood;
      return leftScore >= rightScore ? left : right;
    }
    return null;
  }

  bool _isSideOn(_SidePose side) {
    final other = side.otherShoulder;
    if (other == null || other.likelihood < kMinPositionLikelihood) return false;
    final shoulderWidth = pixelDistance(side.shoulder, other);
    final torsoLength = pixelDistance(side.shoulder, side.hip);
    if (torsoLength <= 0) return false;
    return (shoulderWidth / torsoLength) <= kMaxSideOnShoulderRatio;
  }

  double _alignmentAngle(_SidePose side) =>
      angleBetweenPoints(side.shoulder, side.hip, side.ankle);

  double _elbowAngle(_SidePose side) =>
      angleBetweenPoints(side.shoulder, side.elbow, side.wrist);

  @override
  void processPose(Pose? pose) {
    if (pose == null) {
      _isBodyVisible = false;
      return;
    }

    final side = _selectSide(pose);
    if (side == null) {
      _isBodyVisible = false;
      return;
    }
    _isBodyVisible = true;

    final elbowAngle = _elbowAngle(side);
    final alignmentAngle = _alignmentAngle(side);
    final sideOn = _isSideOn(side);
    final aligned = alignmentAngle >= kMinBodyAlignmentAngle;
    _formOk = sideOn && aligned;
    _lastElbowAngle = elbowAngle;

    final bodyY = (side.shoulder.y + side.hip.y) / 2;
    _smoothedBodyY = _smoothedBodyY == null
        ? bodyY
        : kEmaAlpha * bodyY + (1 - kEmaAlpha) * _smoothedBodyY!;

    if (!_calibrated) {
      _runCalibration(side, elbowAngle, sideOn, aligned);
      return;
    }

    if (!_formOk) {
      // Bad-form frames don't advance the state machine (can't fake a rep
      // by breaking form), but the EMA above still tracked so tracking
      // resumes smoothly once good form returns.
      return;
    }

    final displacementPx = _smoothedBodyY! - _topBodyY!;
    final displacement = displacementPx / _bodyScalePx!;

    switch (_phase) {
      case _PushUpPhase.top:
        if (displacement > kTopDisplacementThreshold) {
          _phase = _PushUpPhase.descending;
        }
      case _PushUpPhase.descending:
        if (displacement >= kDownDisplacementThreshold &&
            elbowAngle <= kBottomElbowAngleMax) {
          _phase = _PushUpPhase.bottom;
        } else if (displacement <= kTopDisplacementThreshold) {
          _phase = _PushUpPhase.top; // Didn't reach bottom - aborted, no rep.
        }
      case _PushUpPhase.bottom:
        if (displacement < kDownDisplacementThreshold) {
          _phase = _PushUpPhase.ascending;
        }
      case _PushUpPhase.ascending:
        if (displacement <= kTopDisplacementThreshold &&
            elbowAngle >= kTopElbowAngleMin) {
          final now = DateTime.now();
          if (_lastRepTime == null || now.difference(_lastRepTime!) >= kMinRepInterval) {
            _repCount++;
            _lastRepTime = now;
          }
          _phase = _PushUpPhase.top;
        } else if (displacement >= kDownDisplacementThreshold) {
          _phase = _PushUpPhase.bottom; // Slipped back down before completing.
        }
    }
  }

  void _runCalibration(_SidePose side, double elbowAngle, bool sideOn, bool aligned) {
    final validFrame = sideOn && aligned && elbowAngle >= kTopElbowAngleMin;
    if (!validFrame) {
      _calibrationStreak = 0;
      _calibrationBodyY.clear();
      _calibrationScale.clear();
      return;
    }

    _calibrationStreak++;
    _calibrationBodyY.add(_smoothedBodyY!);
    _calibrationScale.add(pixelDistance(side.shoulder, side.hip));

    if (_calibrationStreak >= kCalibrationFrameCount) {
      _topBodyY = _calibrationBodyY.reduce((a, b) => a + b) / _calibrationBodyY.length;
      _bodyScalePx =
          _calibrationScale.reduce((a, b) => a + b) / _calibrationScale.length;
      _calibrated = true;
      _phase = _PushUpPhase.top;
    }
  }

  String get _phaseLabel {
    switch (_phase) {
      case _PushUpPhase.top:
        return 'TOP';
      case _PushUpPhase.descending:
        return 'DOWN';
      case _PushUpPhase.bottom:
        return 'BOTTOM';
      case _PushUpPhase.ascending:
        return 'UP';
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
        primaryText:
            _formOk ? 'Hold the position...' : kPushUpSetupInstruction,
        secondaryText: 'Calibrating: $_calibrationStreak / $kCalibrationFrameCount',
        isBodyVisible: true,
      );
    }

    final elbowText = _lastElbowAngle?.toStringAsFixed(0) ?? '--';
    return ExerciseStatus(
      primaryText: 'Reps: $_repCount',
      secondaryText: _formOk
          ? 'Position: $_phaseLabel   •   Elbow: $elbowText°'
          : 'Adjust position: stay side-on with body straight',
      isBodyVisible: true,
    );
  }
}
