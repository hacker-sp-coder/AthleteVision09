import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

/// Landmarks below this confidence are skipped in the overlay entirely,
/// rather than drawn at an unreliable position.
const double kOverlayMinLikelihood = 0.5;

const List<(PoseLandmarkType, PoseLandmarkType)> _kSkeletonConnections = [
  (PoseLandmarkType.nose, PoseLandmarkType.leftShoulder),
  (PoseLandmarkType.nose, PoseLandmarkType.rightShoulder),
  (PoseLandmarkType.leftShoulder, PoseLandmarkType.rightShoulder),
  (PoseLandmarkType.leftShoulder, PoseLandmarkType.leftElbow),
  (PoseLandmarkType.leftElbow, PoseLandmarkType.leftWrist),
  (PoseLandmarkType.rightShoulder, PoseLandmarkType.rightElbow),
  (PoseLandmarkType.rightElbow, PoseLandmarkType.rightWrist),
  (PoseLandmarkType.leftShoulder, PoseLandmarkType.leftHip),
  (PoseLandmarkType.rightShoulder, PoseLandmarkType.rightHip),
  (PoseLandmarkType.leftHip, PoseLandmarkType.rightHip),
  (PoseLandmarkType.leftHip, PoseLandmarkType.leftKnee),
  (PoseLandmarkType.leftKnee, PoseLandmarkType.leftAnkle),
  (PoseLandmarkType.rightHip, PoseLandmarkType.rightKnee),
  (PoseLandmarkType.rightKnee, PoseLandmarkType.rightAnkle),
];

/// Draws ML Kit pose landmarks and a stick-figure skeleton over the live
/// camera preview. Coordinate mapping mirrors the reference implementation
/// from the google_ml_kit_flutter example app (coordinates_translator.dart),
/// which correctly accounts for sensor rotation, front-camera mirroring, and
/// the scale difference between the raw camera image and the displayed
/// preview box.
class PosePainter extends CustomPainter {
  PosePainter({
    required this.pose,
    required this.imageSize,
    required this.rotation,
    required this.cameraLensDirection,
    this.groundGuideImageY,
  });

  final Pose pose;
  final Size imageSize;
  final InputImageRotation rotation;
  final CameraLensDirection cameraLensDirection;

  /// Raw image-space Y of an adaptive ground/reference guide (e.g. derived
  /// from the athlete's own wrist/ankle position), or null to draw none.
  final double? groundGuideImageY;

  double _translateX(double x, Size canvasSize) {
    switch (rotation) {
      case InputImageRotation.rotation90deg:
        return x *
            canvasSize.width /
            (Platform.isIOS ? imageSize.width : imageSize.height);
      case InputImageRotation.rotation270deg:
        return canvasSize.width -
            x *
                canvasSize.width /
                (Platform.isIOS ? imageSize.width : imageSize.height);
      case InputImageRotation.rotation0deg:
      case InputImageRotation.rotation180deg:
        if (cameraLensDirection == CameraLensDirection.back) {
          return x * canvasSize.width / imageSize.width;
        }
        return canvasSize.width - x * canvasSize.width / imageSize.width;
    }
  }

  double _translateY(double y, Size canvasSize) {
    switch (rotation) {
      case InputImageRotation.rotation90deg:
      case InputImageRotation.rotation270deg:
        return y *
            canvasSize.height /
            (Platform.isIOS ? imageSize.height : imageSize.width);
      case InputImageRotation.rotation0deg:
      case InputImageRotation.rotation180deg:
        return y * canvasSize.height / imageSize.height;
    }
  }

  bool _isVisible(PoseLandmark? landmark) {
    return landmark != null && landmark.likelihood >= kOverlayMinLikelihood;
  }

  Offset? _offsetFor(PoseLandmarkType type, Size canvasSize) {
    final landmark = pose.landmarks[type];
    if (!_isVisible(landmark)) return null;
    return Offset(
      _translateX(landmark!.x, canvasSize),
      _translateY(landmark.y, canvasSize),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (imageSize.width <= 0 || imageSize.height <= 0) return;

    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..color = Colors.cyanAccent;

    final dotPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = Colors.yellowAccent;

    for (final (typeA, typeB) in _kSkeletonConnections) {
      final a = _offsetFor(typeA, size);
      final b = _offsetFor(typeB, size);
      if (a == null || b == null) continue;
      canvas.drawLine(a, b, linePaint);
    }

    for (final type in pose.landmarks.keys) {
      final offset = _offsetFor(type, size);
      if (offset == null) continue;
      canvas.drawCircle(offset, 5, dotPaint);
    }

    final guideY = groundGuideImageY;
    if (guideY != null) {
      final guidePaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Colors.orangeAccent;
      final y = _translateY(guideY, size);
      _drawDashedLine(canvas, Offset(0, y), Offset(size.width, y), guidePaint);
    }
  }

  void _drawDashedLine(Canvas canvas, Offset p1, Offset p2, Paint paint) {
    const dashWidth = 12.0;
    const gapWidth = 8.0;
    final totalDx = p2.dx - p1.dx;
    final totalDy = p2.dy - p1.dy;
    final totalLength = Offset(totalDx, totalDy).distance;
    if (totalLength == 0) return;
    final stepX = totalDx / totalLength;
    final stepY = totalDy / totalLength;
    var drawn = 0.0;
    while (drawn < totalLength) {
      final segStart = Offset(p1.dx + stepX * drawn, p1.dy + stepY * drawn);
      final segEndLen = (drawn + dashWidth) < totalLength ? drawn + dashWidth : totalLength;
      final segEnd = Offset(p1.dx + stepX * segEndLen, p1.dy + stepY * segEndLen);
      canvas.drawLine(segStart, segEnd, paint);
      drawn += dashWidth + gapWidth;
    }
  }

  @override
  bool shouldRepaint(covariant PosePainter oldDelegate) {
    return oldDelegate.pose != pose ||
        oldDelegate.imageSize != imageSize ||
        oldDelegate.rotation != rotation ||
        oldDelegate.cameraLensDirection != cameraLensDirection ||
        oldDelegate.groundGuideImageY != groundGuideImageY;
  }
}
