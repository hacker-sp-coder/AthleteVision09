import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import 'angle_cycle_engine.dart';
import 'exercise_config.dart';
import 'exercise_engine.dart';
import 'pose_painter.dart';

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

  bool _cameraReady = false;
  String? _cameraError;
  bool _isRunning = false;
  bool _isDetectorBusy = false;
  int _frameCounter = 0;

  String _statusPrimary = '';
  String? _statusSecondary;
  bool _isBodyVisible = true;

  Pose? _lastPose;
  Size? _lastImageSize;
  InputImageRotation? _lastRotation;

  @override
  void initState() {
    super.initState();
    _engine = switch (widget.exerciseType) {
      ExerciseType.verticalJump => VerticalJumpEngine(userHeightCm: widget.userHeightCm!),
      ExerciseType.pushUp => AngleCycleEngine(config: pushUpExerciseConfig),
      ExerciseType.squat => AngleCycleEngine(config: squatExerciseConfig),
    };
    _poseDetector = PoseDetector(
      options: PoseDetectorOptions(
        model: PoseDetectionModel.base,
        mode: PoseDetectionMode.stream,
      ),
    );
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _initCamera();
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
        ResolutionPreset.medium,
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
    _engine.reset();
    _frameCounter = 0;
    setState(() {
      _isRunning = true;
      _statusPrimary = '';
      _statusSecondary = null;
      _isBodyVisible = true;
      _lastPose = null;
    });
    _controller!.startImageStream(_handleCameraImage);
  }

  Future<void> _onStopPressed() async {
    await _controller?.stopImageStream();
    if (!mounted) return;
    setState(() {
      _isRunning = false;
      _lastPose = null;
    });
  }

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
      final inputImage = _inputImageFromCameraImage(image);
      if (inputImage == null) return;

      final poses = await _poseDetector.processImage(inputImage);
      final pose = poses.isNotEmpty ? poses.first : null;
      _engine.processPose(pose);

      final status = _engine.status;
      if (!mounted) return;
      // Every processed frame is reflected here (not just on status-text
      // change) so the skeleton overlay tracks the body live.
      setState(() {
        _statusPrimary = status.primaryText;
        _statusSecondary = status.secondaryText;
        _isBodyVisible = status.isBodyVisible;
        _lastPose = pose;
        _lastImageSize = inputImage.metadata!.size;
        _lastRotation = inputImage.metadata!.rotation;
      });
    } catch (e) {
      debugPrint('Pose processing error: $e');
    } finally {
      _isDetectorBusy = false;
    }
  }

  InputImage? _inputImageFromCameraImage(CameraImage image) {
    final controller = _controller;
    if (controller == null || _cameras.isEmpty) return null;

    final camera = _cameras[_cameraIndex];
    final sensorOrientation = camera.sensorOrientation;
    InputImageRotation? rotation;
    if (Platform.isIOS) {
      rotation = InputImageRotationValue.fromRawValue(sensorOrientation);
    } else if (Platform.isAndroid) {
      var rotationCompensation = _orientations[controller.value.deviceOrientation];
      if (rotationCompensation == null) return null;
      if (camera.lensDirection == CameraLensDirection.front) {
        rotationCompensation = (sensorOrientation + rotationCompensation) % 360;
      } else {
        rotationCompensation = (sensorOrientation - rotationCompensation + 360) % 360;
      }
      rotation = InputImageRotationValue.fromRawValue(rotationCompensation);
    }
    if (rotation == null) return null;

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null ||
        (Platform.isAndroid && format != InputImageFormat.nv21) ||
        (Platform.isIOS && format != InputImageFormat.bgra8888)) {
      return null;
    }

    if (image.planes.length != 1) return null;
    final plane = image.planes.first;

    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  @override
  void dispose() {
    _controller?.stopImageStream();
    _controller?.dispose();
    _poseDetector.close();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  String get _title => switch (widget.exerciseType) {
    ExerciseType.verticalJump => 'Standing Vertical Jump',
    ExerciseType.pushUp => 'Push-ups',
    ExerciseType.squat => 'Squats',
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
              if (_lastPose != null && _lastImageSize != null && _lastRotation != null)
                CustomPaint(
                  painter: PosePainter(
                    pose: _lastPose!,
                    imageSize: _lastImageSize!,
                    rotation: _lastRotation!,
                    cameraLensDirection: _cameras[_cameraIndex].lensDirection,
                    groundGuideImageY: _engine.groundGuideImageY,
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
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: _isRunning ? _onStopPressed : _onStartPressed,
                child: Text(_isRunning ? 'Stop' : 'Start'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
