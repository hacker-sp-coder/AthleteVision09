import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import 'angle_cycle_engine.dart';
import 'audio/exercise_voice_coach.dart';
import 'audio/voice_feedback_service.dart';
import 'exercise_config.dart';
import 'exercise_engine.dart';
import 'identity/identity_state.dart';
import 'identity/identity_verifier.dart';
import 'plank_engine.dart';
import 'pose_frame_downscale.dart';
import 'pose_painter.dart';
import 'vertical_jump_engine.dart';
import 'wall_sit_engine.dart';

class LiveTestScreen extends StatefulWidget {
  const LiveTestScreen({
    super.key,
    required this.exerciseType,
    this.userHeightCm,
  }) : assert(
         exerciseType != ExerciseType.verticalJump || userHeightCm != null,
         'userHeightCm is required for the vertical jump test',
       );

  final ExerciseType exerciseType;
  final double? userHeightCm;

  @override
  State<LiveTestScreen> createState() => _LiveTestScreenState();
}

class _LiveTestScreenState extends State<LiveTestScreen> {
  static const int _frameSkip = 2;

  /// Camera stream downscale factor applied before frames reach the pose
  /// detector (see pose_frame_downscale.dart). The camera stream itself
  /// runs at ResolutionPreset.high (~1280x720) so periodic identity
  /// verification gets the full native resolution; this keeps the
  /// continuous pose pipeline operating on a comparable-or-smaller image
  /// than it did at the previous ResolutionPreset.medium (~720x480) -
  /// 1280x720 downscaled by 2 is 640x360, fewer total pixels than before.
  /// Identity verification never uses this - it always reads the
  /// original, undownscaled CameraImage.
  static const int _poseDownscaleFactor = 2;

  /// How long the most recently displayed pose is kept on screen after a
  /// processed frame returns no pose at all, before the skeleton overlay is
  /// cleared. Purely visual hysteresis to bridge a transient ML Kit
  /// detection miss (e.g. motion blur near a jump's peak) - the exercise
  /// engine always receives the real per-frame result regardless of this.
  static const Duration _poseDisplayGracePeriod = Duration(milliseconds: 250);

  static const Map<DeviceOrientation, int> _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  int _cameraIndex = 0;
  late final PoseDetector _poseDetector;
  late final ExerciseEngine _engine;

  /// Isolated identity-verification layer - see lib/identity/. Entirely
  /// separate from [_engine]; never affects exercise scoring/rep logic.
  late final IdentityVerifier _identityVerifier;
  bool _isEnrolling = false;
  bool _enrollBusy = false;
  String? _enrollmentMessage;

  /// Isolated voice-coaching layer - see lib/audio/. Reads [_engine]'s
  /// existing status/getters only; never affects exercise scoring/rep
  /// logic. [ExerciseVoiceCoach] itself only speaks for push-up/plank/
  /// vertical jump - a no-op for every other exercise.
  late final VoiceFeedbackService _voiceService;
  late final ExerciseVoiceCoach _voiceCoach;

  bool _cameraReady = false;
  String? _cameraError;
  bool _isRunning = false;
  bool _isDetectorBusy = false;
  int _frameCounter = 0;

  String _statusPrimary = '';
  String? _statusSecondary;
  bool _isBodyVisible = true;

  /// The pose currently shown by the skeleton overlay. Distinct from the
  /// per-frame result passed to [_engine] - this may briefly still hold the
  /// previous frame's pose during a transient ML Kit miss (see
  /// [_poseDisplayGracePeriod]), which the engine must never see.
  Pose? _displayPose;
  DateTime? _displayPoseSeenAt;
  Size? _lastImageSize;
  InputImageRotation? _lastRotation;

  @override
  void initState() {
    super.initState();
    _engine = switch (widget.exerciseType) {
      ExerciseType.verticalJump => VerticalJumpEngine(userHeightCm: widget.userHeightCm!),
      ExerciseType.pushUp => AngleCycleEngine(config: pushUpExerciseConfig),
      ExerciseType.squat => AngleCycleEngine(config: squatExerciseConfig),
      ExerciseType.controlledCrunch =>
        AngleCycleEngine(config: controlledCrunchExerciseConfig),
      ExerciseType.wallSit => WallSitEngine(),
      ExerciseType.plank => PlankEngine(),
    };
    _poseDetector = PoseDetector(
      options: PoseDetectorOptions(
        model: PoseDetectionModel.base,
        mode: PoseDetectionMode.stream,
      ),
    );
    _identityVerifier = IdentityVerifier()..addListener(_onIdentityChanged);
    _voiceService = VoiceFeedbackService();
    _voiceCoach = ExerciseVoiceCoach(voice: _voiceService, exerciseType: widget.exerciseType);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _initCamera();
  }

  void _onIdentityChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        if (!mounted) return;
        setState(() => _cameraError = 'No camera found on this device.');
        return;
      }
      _cameraIndex = _cameras.indexWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
      );
      if (_cameraIndex < 0) _cameraIndex = 0;

      final controller = CameraController(
        _cameras[_cameraIndex],
        // Raised from .medium so periodic identity verification (Phase 2)
        // gets more native face pixels at typical full-body test distance
        // - see pose_frame_downscale.dart for how the continuous pose
        // pipeline is kept off this full resolution.
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.nv21
            : ImageFormatGroup.bgra8888,
      );
      _controller = controller;
      await controller.initialize();
      if (!mounted) return;
      setState(() => _cameraReady = true);
    } on CameraException catch (e) {
      if (!mounted) return;
      setState(() => _cameraError = e.description ?? 'Failed to access camera.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _cameraError = 'Failed to access camera: $e');
    }
  }

  void _onStartPressed() {
    if (!_identityVerifier.hasReference) return;
    // Marks this exact moment - not enrollment success, not camera-stream
    // start - as when the test becomes active, arming the identity
    // verifier's 7-second periodic-check timer from here.
    _identityVerifier.activate();
    _engine.reset();
    _voiceCoach.onTestStarted();
    _frameCounter = 0;
    _displayPoseSeenAt = null;
    setState(() {
      _isRunning = true;
      _statusPrimary = '';
      _statusSecondary = null;
      _isBodyVisible = true;
      _displayPose = null;
    });
    _controller!.startImageStream(_handleCameraImage);
  }

  Future<void> _onStopPressed() async {
    _voiceCoach.onStopPressed(_engine);
    await _controller?.stopImageStream();
    if (!mounted) return;
    _displayPoseSeenAt = null;
    // Test/session has ended: the reference embedding must not outlive it
    // (privacy - no persistence beyond the current test).
    _identityVerifier.reset();
    setState(() {
      _isRunning = false;
      _displayPose = null;
    });
  }

  /// Captures a reference face embedding from the next usable camera
  /// frame, reusing the same camera pipeline (startImageStream) as the
  /// exercise test itself rather than a second capture path. Requires
  /// exactly one detectable, adequately-sized face; keeps listening on
  /// subsequent frames until it gets one or the user cancels.
  void _startEnrollment() {
    if (_controller == null || !_cameraReady || _isRunning) return;
    setState(() {
      _isEnrolling = true;
      _enrollmentMessage = 'Look at the camera...';
    });
    _controller!.startImageStream(_handleEnrollmentImage);
  }

  void _cancelEnrollment() {
    _controller?.stopImageStream();
    if (!mounted) return;
    setState(() {
      _isEnrolling = false;
      _enrollmentMessage = null;
    });
  }

  void _handleEnrollmentImage(CameraImage image) {
    if (!_isEnrolling || _enrollBusy) return;
    _enrollBusy = true;
    _processEnrollmentFrame(image);
  }

  Future<void> _processEnrollmentFrame(CameraImage image) async {
    try {
      final controller = _controller;
      if (controller == null) return;
      final rotation = _computeRotation(controller);
      if (rotation == null) return;

      final result = await _identityVerifier.tryEnrollFromFrame(
        image: image,
        rotation: rotation,
      );
      if (!mounted) return;

      if (result == EnrollmentResult.success) {
        await controller.stopImageStream();
        if (!mounted) return;
        setState(() {
          _isEnrolling = false;
          _enrollmentMessage = 'Reference photo captured';
        });
      } else {
        setState(() => _enrollmentMessage = _enrollmentMessageFor(result));
      }
    } finally {
      _enrollBusy = false;
    }
  }

  String _enrollmentMessageFor(EnrollmentResult result) => switch (result) {
    EnrollmentResult.success => 'Reference photo captured',
    EnrollmentResult.noFaceDetected => 'No face detected - look at the camera',
    EnrollmentResult.multipleFacesDetected => 'Multiple faces detected - only one person allowed',
    EnrollmentResult.faceTooSmall => 'Move closer so your face fills more of the frame',
    EnrollmentResult.error => 'Could not capture reference photo - try again',
  };

  void _handleCameraImage(CameraImage image) {
    if (!_isRunning) return;
    _frameCounter++;
    if (_frameCounter % _frameSkip != 0) return;
    if (_isDetectorBusy) return;
    _isDetectorBusy = true;
    _processImage(image);
  }

  Future<void> _processImage(CameraImage image) async {
    try {
      final controller = _controller;
      if (controller == null || _cameras.isEmpty) return;

      // Computed once per frame and shared by both paths below, so pose
      // and identity verification always agree on the phone's current
      // orientation even though they otherwise read the frame at
      // different resolutions.
      final rotation = _computeRotation(controller);
      if (rotation == null) return;

      // Pose: downscaled frame (see pose_frame_downscale.dart) - the
      // camera stream itself runs at ResolutionPreset.high for identity
      // verification's benefit, but pose has no need for those extra
      // pixels and shouldn't pay for them every frame.
      final poseInputImage = _downscaledPoseInputImage(image, rotation);
      if (poseInputImage == null) return;

      final poses = await _poseDetector.processImage(poseInputImage);
      final pose = poses.isNotEmpty ? poses.first : null;
      // The exercise engine always sees this frame's real result - never
      // the held display pose computed below.
      _engine.processPose(pose);

      // Identity check: independent of pose/exercise scoring, gated to a
      // fixed ~7s cadence internally (not every processed frame). Uses
      // the ORIGINAL, undownscaled `image` directly - this is the whole
      // point of Phase 2 (more native face pixels at ~2.5-3m). Fired
      // without awaiting so a periodic identity check never delays pose
      // status updates.
      unawaited(_identityVerifier.maybeVerify(image: image, rotation: rotation));

      final status = _engine.status;
      // Voice coaching: reads _engine's existing status/getters only,
      // never alters them. No-op for exercises other than push-up/plank/
      // vertical jump.
      _voiceCoach.onFrame(_engine, status);
      if (!mounted) return;

      final now = DateTime.now();
      final Pose? displayPose;
      if (pose != null) {
        displayPose = pose;
        _displayPoseSeenAt = now;
      } else if (_displayPose != null &&
          _displayPoseSeenAt != null &&
          now.difference(_displayPoseSeenAt!) <= _poseDisplayGracePeriod) {
        // Transient ML Kit miss - briefly keep showing the last known-good
        // pose. Display-only: this frame's real (null) result already went
        // to the engine above.
        displayPose = _displayPose;
      } else {
        displayPose = null;
      }

      // Every processed frame is reflected here (not just on status-text
      // change) so the skeleton overlay tracks the body live. imageSize
      // here is the DOWNSCALED size (matching what pose/[_engine] actually
      // saw), which PosePainter needs to correctly scale landmark
      // coordinates onto the (full-resolution) preview canvas - it works
      // off the ratio between imageSize and the canvas, not absolute
      // pixel counts, so this is correct regardless of which resolution
      // pose happens to run at.
      setState(() {
        _statusPrimary = status.primaryText;
        _statusSecondary = status.secondaryText;
        _isBodyVisible = status.isBodyVisible;
        _displayPose = displayPose;
        _lastImageSize = poseInputImage.metadata!.size;
        _lastRotation = poseInputImage.metadata!.rotation;
      });
    } catch (e) {
      debugPrint('Pose processing error: $e');
    } finally {
      _isDetectorBusy = false;
    }
  }

  /// Sensor-to-upright rotation for the current camera + device
  /// orientation. Shared by pose-detection frame conversion and
  /// identity-verification frame conversion so both interpret raw camera
  /// bytes identically.
  InputImageRotation? _computeRotation(CameraController controller) {
    final camera = _cameras[_cameraIndex];
    final sensorOrientation = camera.sensorOrientation;
    if (Platform.isIOS) {
      return InputImageRotationValue.fromRawValue(sensorOrientation);
    } else if (Platform.isAndroid) {
      var rotationCompensation = _orientations[controller.value.deviceOrientation];
      if (rotationCompensation == null) return null;
      if (camera.lensDirection == CameraLensDirection.front) {
        rotationCompensation = (sensorOrientation + rotationCompensation) % 360;
      } else {
        rotationCompensation = (sensorOrientation - rotationCompensation + 360) % 360;
      }
      return InputImageRotationValue.fromRawValue(rotationCompensation);
    }
    return null;
  }

  /// Builds the pose detector's [InputImage] from a downscaled copy of
  /// [image] (see [_poseDownscaleFactor]/pose_frame_downscale.dart) - not
  /// the original full-resolution frame. [rotation] is passed in rather
  /// than recomputed so pose and identity verification (which uses the
  /// same [rotation] value on the original frame) can never disagree.
  InputImage? _downscaledPoseInputImage(CameraImage image, InputImageRotation rotation) {
    final downscaled = downscaleCameraImage(image, _poseDownscaleFactor);
    if (downscaled == null) return null;

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null ||
        (Platform.isAndroid && format != InputImageFormat.nv21) ||
        (Platform.isIOS && format != InputImageFormat.bgra8888)) {
      return null;
    }

    return InputImage.fromBytes(
      bytes: downscaled.bytes,
      metadata: InputImageMetadata(
        size: Size(downscaled.width.toDouble(), downscaled.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: downscaled.bytesPerRow,
      ),
    );
  }

  @override
  void dispose() {
    _controller?.stopImageStream();
    _controller?.dispose();
    _poseDetector.close();
    _identityVerifier
      ..removeListener(_onIdentityChanged)
      ..dispose();
    _voiceService.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  /// TEMPORARY DEBUG-only text for physical-testing lifecycle audits - see
  /// the debug indicator in [_buildBody]. Remove once the real identity UI
  /// is built.
  String _identityDebugText() {
    final snapshot = _identityVerifier.snapshot;
    final label = switch (snapshot.state) {
      IdentityVerificationState.referenceNotCaptured => 'NO REFERENCE',
      IdentityVerificationState.referenceReady => 'REFERENCE',
      IdentityVerificationState.checking => 'CHECKING',
      IdentityVerificationState.match => 'MATCH',
      IdentityVerificationState.inconclusive => 'INCONCLUSIVE',
      IdentityVerificationState.mismatch => 'MISMATCH',
      IdentityVerificationState.identityMismatchConfirmed => 'IDENTITY FAILED',
    };
    final similarity = snapshot.lastSimilarity;
    final simText = similarity == null ? '' : '  sim=${similarity.toStringAsFixed(3)}';
    final reason = _identityVerifier.debugLastInconclusiveReason;
    final reasonText =
        snapshot.state == IdentityVerificationState.inconclusive && reason != null
        ? '  reason=$reason'
        : '';
    return 'DEBUG ID: $label$simText$reasonText  '
        '(mism=${snapshot.consecutiveMismatchCount} inconcl=${snapshot.inconclusiveCount})';
  }

  String get _title => switch (widget.exerciseType) {
    ExerciseType.verticalJump => 'Standing Vertical Jump',
    ExerciseType.pushUp => 'Push-ups',
    ExerciseType.squat => 'Squats',
    ExerciseType.controlledCrunch => 'Controlled Crunch',
    ExerciseType.wallSit => 'Wall-Sit Hold',
    ExerciseType.plank => 'Straight-Arm Plank',
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_cameraError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_cameraError!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () {
                  setState(() => _cameraError = null);
                  _initCamera();
                },
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (!_cameraReady || _controller == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              CameraPreview(_controller!),
              if (_isRunning && _engine.showPositionGuide)
                Positioned.fill(
                  child: FractionallySizedBox(
                    alignment: Alignment.bottomCenter,
                    widthFactor: 0.64,
                    heightFactor: 0.8,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white70, width: 2),
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ),
              if (_displayPose != null && _lastImageSize != null && _lastRotation != null)
                CustomPaint(
                  painter: PosePainter(
                    pose: _displayPose!,
                    imageSize: _lastImageSize!,
                    rotation: _lastRotation!,
                    cameraLensDirection: _cameras[_cameraIndex].lensDirection,
                    groundGuideImageY: _engine.groundGuideImageY,
                  ),
                ),
              // TEMPORARY: on-screen diagnostic overlay for physical
              // testing without a USB-attached console. Remove once no
              // longer needed.
              if (_engine.diagnosticText != null)
                Positioned(
                  top: 8,
                  left: 8,
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _engine.diagnosticText!,
                      style: const TextStyle(
                        color: Colors.greenAccent,
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
              // Minimal identity-mismatch indicator - proper UI TBD. Purely
              // informational: never touches exercise status/scoring.
              if (_identityVerifier.snapshot.state ==
                  IdentityVerificationState.identityMismatchConfirmed)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.red.shade700,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      'Identity verification failed',
                      style: TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                ),
              // TEMPORARY DEBUG instrumentation for physical-testing
              // lifecycle audits - remove once the real identity UI is
              // built. Unlike the mismatch banner above (which only shows
              // on confirmed failure), this always reflects the live
              // IdentityVerificationState so REFERENCE/CHECKING/MATCH/
              // INCONCLUSIVE/MISMATCH are visible, not just the terminal
              // failure state.
              Positioned(
                bottom: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _identityDebugText(),
                    style: const TextStyle(
                      color: Colors.amberAccent,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _statusPrimary.isEmpty ? 'Press Start to begin' : _statusPrimary,
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              if (_statusSecondary != null) ...[
                const SizedBox(height: 4),
                Text(_statusSecondary!, textAlign: TextAlign.center),
              ],
              if (_isRunning && !_isBodyVisible) ...[
                const SizedBox(height: 4),
                Text(
                  'Body not fully visible - adjust position',
                  style: TextStyle(color: Colors.orange.shade800),
                  textAlign: TextAlign.center,
                ),
              ],
              // Minimal identity-enrollment step - proper UI TBD. Required
              // before Start so a reference embedding exists for the test.
              if (!_isRunning) ...[
                const SizedBox(height: 12),
                Text(
                  _enrollmentMessage ??
                      (_identityVerifier.hasReference
                          ? 'Reference photo captured'
                          : 'Capture a reference photo before starting'),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                ElevatedButton(
                  onPressed: _isEnrolling ? _cancelEnrollment : _startEnrollment,
                  child: Text(
                    _isEnrolling
                        ? 'Cancel'
                        : (_identityVerifier.hasReference
                              ? 'Re-capture Reference Photo'
                              : 'Capture Reference Photo'),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: _isRunning
                    ? _onStopPressed
                    : (_identityVerifier.hasReference ? _onStartPressed : null),
                child: Text(_isRunning ? 'Stop' : 'Start'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
