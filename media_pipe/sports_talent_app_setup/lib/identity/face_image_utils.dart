import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;

import 'identity_config.dart';

/// Whether a detected face is large enough (relative to the frame's shorter
/// side) to embed reliably. Too-small faces are treated as INCONCLUSIVE by
/// the caller rather than compared.
bool isFaceUsable(Face face, {required double imageWidth, required double imageHeight}) {
  final shorterSide = math.min(imageWidth, imageHeight);
  if (shorterSide <= 0) return false;
  final faceSize = math.min(face.boundingBox.width, face.boundingBox.height);
  return faceSize / shorterSide >= kMinFaceSizeFractionV1;
}

/// TEMPORARY DEBUG hook: reports the source region used to build the final
/// 112x112 image, plus that final image itself, so a caller can log/save
/// it for physical-testing comparison between the enrollment and
/// verification crops. For the landmark-aligned path (see
/// [_kAlignmentLandmarkTypes]), left/top/width/height describe the
/// axis-aligned bounding box of the 5 raw landmark points used to fit the
/// alignment transform, not a literal crop rectangle - alignment doesn't
/// crop a rectangle first. `aligned` is true when landmark alignment was
/// used, false when the bounding-box+margin fallback was used instead. Not
/// used by production logic.
typedef CropDebugInfo = ({
  int left,
  int top,
  int width,
  int height,
  bool aligned,
  img.Image finalCrop,
});

/// Canonical 112x112 5-point face template (the standard ArcFace/
/// InsightFace alignment convention reused across essentially all
/// MobileFaceNet-class models trained on aligned faces - see project
/// report). Subject-relative left/right, matching ML Kit's own
/// [FaceLandmarkType] convention. Order matches
/// [_kAlignmentLandmarkTypes]: leftEye, rightEye, noseBase, leftMouth,
/// rightMouth.
const List<(double, double)> kCanonicalFacePoints112 = [
  (38.2946, 51.6963),
  (73.5318, 51.5014),
  (56.0252, 71.7366),
  (41.5493, 92.3655),
  (70.7299, 92.2041),
];

const List<FaceLandmarkType> _kAlignmentLandmarkTypes = [
  FaceLandmarkType.leftEye,
  FaceLandmarkType.rightEye,
  FaceLandmarkType.noseBase,
  FaceLandmarkType.leftMouth,
  FaceLandmarkType.rightMouth,
];

/// Builds a ready-to-run [1,112,112,3] float32 tensor (RGB, values in
/// [-1, 1] - matching the upstream model's own preprocessing convention)
/// for [face] from the raw camera frame.
///
/// Prefers 5-point similarity-transform alignment (rotates, scales, and
/// translates directly from the detected eye/nose/mouth landmarks onto the
/// model's expected canonical positions - see [kCanonicalFacePoints112])
/// whenever ML Kit returned all 5 required landmarks. This is what
/// MobileFaceNet-class models are trained to expect, and - because the
/// alignment transform is solved directly from the landmarks' own
/// positions - it is inherently robust to whatever rotation the raw
/// buffer happens to be in, so [rotation] is unused on this path.
///
/// Falls back to the coarser axis-aligned bounding-box crop (margined,
/// letterboxed, rotated by [rotation]) when landmarks aren't available
/// (e.g. `enableLandmarks` off, or ML Kit didn't resolve all 5 for this
/// face) - this is the same fallback logic used before alignment was
/// added, unchanged.
///
/// Operates on the same [CameraImage] already produced by the existing
/// pose-detection image stream (NV21 on Android / BGRA8888 on iOS,
/// single-plane, matching the assumptions already made in
/// `live_test_screen.dart`'s pose pipeline) - no second camera capture
/// path is introduced.
Float32List? prepareEmbeddingTensor({
  required CameraImage image,
  required Face face,
  required InputImageRotation rotation,
  void Function(CropDebugInfo info)? onDebugCrop,
}) {
  final aligned = _tryAlignFace(image, face, onDebugCrop: onDebugCrop);
  final resized = aligned ?? _cropAndLetterbox(image, face, rotation, onDebugCrop: onDebugCrop);
  if (resized == null) return null;

  final tensor = Float32List(kFaceEmbeddingInputSize * kFaceEmbeddingInputSize * 3);
  var i = 0;
  for (var y = 0; y < resized.height; y++) {
    for (var x = 0; x < resized.width; x++) {
      final px = resized.getPixel(x, y);
      tensor[i++] = (px.r / 127.5) - 1.0;
      tensor[i++] = (px.g / 127.5) - 1.0;
      tensor[i++] = (px.b / 127.5) - 1.0;
    }
  }
  return tensor;
}

// ---------------------------------------------------------------------
// Landmark-based 5-point similarity alignment (primary path)
// ---------------------------------------------------------------------

img.Image? _tryAlignFace(
  CameraImage image,
  Face face, {
  void Function(CropDebugInfo info)? onDebugCrop,
}) {
  final points = _extractAlignmentPoints(face);
  if (points == null) return null;

  final transform = _fitSimilarityTransform(points, kCanonicalFacePoints112);
  final canvas = _rasterizeAligned(image, transform, kFaceEmbeddingInputSize);
  if (canvas == null) return null;

  var minX = points[0].$1, maxX = points[0].$1, minY = points[0].$2, maxY = points[0].$2;
  for (final p in points) {
    if (p.$1 < minX) minX = p.$1;
    if (p.$1 > maxX) maxX = p.$1;
    if (p.$2 < minY) minY = p.$2;
    if (p.$2 > maxY) maxY = p.$2;
  }
  onDebugCrop?.call((
    left: minX.floor(),
    top: minY.floor(),
    width: (maxX - minX).ceil(),
    height: (maxY - minY).ceil(),
    aligned: true,
    finalCrop: canvas,
  ));
  return canvas;
}

/// Extracts the 5 alignment landmark positions from [face], in raw
/// (unrotated) camera-buffer coordinates - the same space as
/// `face.boundingBox`. Returns null if any of the 5 required landmarks
/// wasn't detected.
List<(double, double)>? _extractAlignmentPoints(Face face) {
  final points = <(double, double)>[];
  for (final type in _kAlignmentLandmarkTypes) {
    final landmark = face.landmarks[type];
    if (landmark == null) return null;
    points.add((landmark.position.x.toDouble(), landmark.position.y.toDouble()));
  }
  return points;
}

/// Least-squares similarity transform (uniform scale + rotation +
/// translation only - never reflection/shear) mapping [src] points onto
/// [dst] points, expressed as a complex affine map z -> a*z + b (points as
/// z = x + iy). Returns (aRe, aIm, bRe, bIm).
///
/// This is the closed-form solution minimizing sum |a*src_i + b - dst_i|^2
/// - equivalent to a 2D Procrustes/Umeyama fit restricted to
/// orientation-preserving similarity transforms, which is exactly what
/// face alignment needs (a face must never be mirror-flipped).
(double, double, double, double) _fitSimilarityTransform(
  List<(double, double)> src,
  List<(double, double)> dst,
) {
  final n = src.length;
  var srcMeanX = 0.0, srcMeanY = 0.0, dstMeanX = 0.0, dstMeanY = 0.0;
  for (var i = 0; i < n; i++) {
    srcMeanX += src[i].$1;
    srcMeanY += src[i].$2;
    dstMeanX += dst[i].$1;
    dstMeanY += dst[i].$2;
  }
  srcMeanX /= n;
  srcMeanY /= n;
  dstMeanX /= n;
  dstMeanY /= n;

  var numRe = 0.0, numIm = 0.0, den = 0.0;
  for (var i = 0; i < n; i++) {
    final sx = src[i].$1 - srcMeanX;
    final sy = src[i].$2 - srcMeanY;
    final dx = dst[i].$1 - dstMeanX;
    final dy = dst[i].$2 - dstMeanY;
    // conj(s) * d = (sx - i*sy) * (dx + i*dy)
    numRe += sx * dx + sy * dy;
    numIm += sx * dy - sy * dx;
    den += sx * sx + sy * sy;
  }
  if (den == 0) {
    return (1, 0, dstMeanX - srcMeanX, dstMeanY - srcMeanY);
  }
  final aRe = numRe / den;
  final aIm = numIm / den;
  final bRe = dstMeanX - (aRe * srcMeanX - aIm * srcMeanY);
  final bIm = dstMeanY - (aRe * srcMeanY + aIm * srcMeanX);
  return (aRe, aIm, bRe, bIm);
}

/// Rasterizes a [targetSize]x[targetSize] image by, for every destination
/// pixel, inverse-mapping through [transform] (dst = a*src + b) back into
/// raw camera-buffer coordinates and bilinearly sampling there. Standard
/// inverse-warp rasterization - avoids the holes a forward warp would
/// leave. Destination pixels whose source falls outside the raw buffer
/// are left black (matching the fallback path's letterbox padding).
img.Image? _rasterizeAligned(
  CameraImage image,
  (double, double, double, double) transform,
  int targetSize,
) {
  final (aRe, aIm, bRe, bIm) = transform;
  final aMagSq = aRe * aRe + aIm * aIm;
  if (aMagSq == 0) return null;
  if (image.planes.length != 1) return null;

  final canvas = img.Image(width: targetSize, height: targetSize);
  for (var dy = 0; dy < targetSize; dy++) {
    for (var dx = 0; dx < targetSize; dx++) {
      final ddx = dx - bRe;
      final ddy = dy - bIm;
      // (ddx + i*ddy) / (aRe + i*aIm)
      final srcX = (ddx * aRe + ddy * aIm) / aMagSq;
      final srcY = (ddy * aRe - ddx * aIm) / aMagSq;
      final sample = _bilinearSample(image, srcX, srcY);
      if (sample != null) {
        canvas.setPixelRgb(
          dx,
          dy,
          sample.$1.round().clamp(0, 255),
          sample.$2.round().clamp(0, 255),
          sample.$3.round().clamp(0, 255),
        );
      }
      // Else: leave black (canvas is zero-initialized) - matches the
      // fallback path's letterbox padding convention.
    }
  }
  return canvas;
}

/// Bilinear RGB sample at fractional raw-buffer coordinates. Null if
/// entirely outside the buffer.
(double, double, double)? _bilinearSample(CameraImage image, double x, double y) {
  if (x < 0 || y < 0 || x > image.width - 1 || y > image.height - 1) return null;
  final x0 = x.floor();
  final y0 = y.floor();
  final x1 = math.min(x0 + 1, image.width - 1);
  final y1 = math.min(y0 + 1, image.height - 1);
  final fx = x - x0;
  final fy = y - y0;

  final p00 = _rawPixelAt(image, x0, y0);
  final p10 = _rawPixelAt(image, x1, y0);
  final p01 = _rawPixelAt(image, x0, y1);
  final p11 = _rawPixelAt(image, x1, y1);
  if (p00 == null || p10 == null || p01 == null || p11 == null) return null;

  double blend(int a, int b, int c, int d) {
    final top = a + (b - a) * fx;
    final bottom = c + (d - c) * fx;
    return top + (bottom - top) * fy;
  }

  return (
    blend(p00.$1, p10.$1, p01.$1, p11.$1),
    blend(p00.$2, p10.$2, p01.$2, p11.$2),
    blend(p00.$3, p10.$3, p01.$3, p11.$3),
  );
}

// ---------------------------------------------------------------------
// Bounding-box + margin crop (fallback path, used when landmarks aren't
// available)
// ---------------------------------------------------------------------

img.Image? _cropAndLetterbox(
  CameraImage image,
  Face face,
  InputImageRotation rotation, {
  void Function(CropDebugInfo info)? onDebugCrop,
}) {
  final box = face.boundingBox;
  final marginX = box.width * kFaceCropMarginFractionV1;
  final marginY = box.height * kFaceCropMarginFractionV1;
  final left = (box.left - marginX).clamp(0.0, (image.width - 1).toDouble()).floor();
  final top = (box.top - marginY).clamp(0.0, (image.height - 1).toDouble()).floor();
  final right = (box.right + marginX).clamp(0.0, image.width.toDouble()).ceil();
  final bottom = (box.bottom + marginY).clamp(0.0, image.height.toDouble()).ceil();
  final width = right - left;
  final height = bottom - top;
  if (width <= 0 || height <= 0) return null;

  var crop = _decodeRegion(image, left, top, width, height);
  if (crop == null) return null;

  crop = _applyRotation(crop, rotation);

  // Letterbox (aspect-preserving) resize, not a squash/stretch resize:
  // matches the bundled model's own documented preprocessing convention
  // (scale to fit, pad with black to a square) - see project report. A
  // plain non-aspect-preserving resize would stretch the face by a
  // different amount depending on the crop's aspect ratio, which varies
  // frame-to-frame with face angle/distance - i.e. a real inconsistency
  // between the enrollment crop and any later verification crop, not just
  // a cosmetic difference.
  final resized = _letterboxResize(crop, kFaceEmbeddingInputSize);

  onDebugCrop?.call((
    left: left,
    top: top,
    width: width,
    height: height,
    aligned: false,
    finalCrop: resized,
  ));
  return resized;
}

/// Scales [crop] so its longer side becomes [targetSize], preserving
/// aspect ratio, then centers it on a black [targetSize]x[targetSize]
/// canvas. Never distorts the face's proportions, unlike a plain resize.
img.Image _letterboxResize(img.Image crop, int targetSize) {
  final scale = targetSize / math.max(crop.width, crop.height);
  final scaledW = (crop.width * scale).round().clamp(1, targetSize);
  final scaledH = (crop.height * scale).round().clamp(1, targetSize);
  final scaledCrop = img.copyResize(
    crop,
    width: scaledW,
    height: scaledH,
    interpolation: img.Interpolation.linear,
  );

  // A freshly constructed Image is zero-initialized (black), matching the
  // reference preprocessing's black letterbox padding.
  final canvas = img.Image(width: targetSize, height: targetSize);
  final offsetX = ((targetSize - scaledW) / 2).round();
  final offsetY = ((targetSize - scaledH) / 2).round();
  for (var y = 0; y < scaledH; y++) {
    for (var x = 0; x < scaledW; x++) {
      final px = scaledCrop.getPixel(x, y);
      canvas.setPixelRgb(offsetX + x, offsetY + y, px.r, px.g, px.b);
    }
  }
  return canvas;
}

img.Image _applyRotation(img.Image image, InputImageRotation rotation) {
  final degrees = switch (rotation) {
    InputImageRotation.rotation90deg => 90,
    InputImageRotation.rotation180deg => 180,
    InputImageRotation.rotation270deg => 270,
    InputImageRotation.rotation0deg => 0,
  };
  if (degrees == 0) return image;
  return img.copyRotate(image, angle: degrees);
}

img.Image? _decodeRegion(CameraImage image, int left, int top, int width, int height) {
  if (image.planes.length != 1) return null;
  if (!_hasSupportedFormat(image)) return null;

  final out = img.Image(width: width, height: height);
  for (var ry = 0; ry < height; ry++) {
    final y = top + ry;
    for (var rx = 0; rx < width; rx++) {
      final x = left + rx;
      final pixel = _rawPixelAt(image, x, y);
      if (pixel != null) {
        out.setPixelRgb(rx, ry, pixel.$1, pixel.$2, pixel.$3);
      }
    }
  }
  return out;
}

bool _hasSupportedFormat(CameraImage image) =>
    image.format.group == ImageFormatGroup.nv21 ||
    image.format.group == ImageFormatGroup.bgra8888;

/// Reads one exact-integer pixel's RGB directly from the raw camera
/// buffer (NV21 on Android / BGRA8888 on iOS, single-plane - matching the
/// assumptions already made in `live_test_screen.dart`'s pose pipeline).
/// Shared by the axis-aligned region crop and the landmark-alignment
/// bilinear sampler, so both read pixels identically. Null if out of
/// bounds or the plane layout isn't single-plane NV21/BGRA8888.
(int, int, int)? _rawPixelAt(CameraImage image, int x, int y) {
  if (x < 0 || y < 0 || x >= image.width || y >= image.height) return null;
  if (image.planes.length != 1) return null;
  final plane = image.planes.first;
  switch (image.format.group) {
    case ImageFormatGroup.nv21:
      return _nv21PixelAt(plane.bytes, plane.bytesPerRow, image.height, x, y);
    case ImageFormatGroup.bgra8888:
      return _bgraPixelAt(plane.bytes, plane.bytesPerRow, x, y);
    default:
      return null;
  }
}

/// Standard BT.601-ish NV21 (Y plane + interleaved VU plane) to RGB
/// conversion for one pixel, using the well-known mobile conversion
/// coefficients. Not colorimetrically calibrated - adequate for face
/// embedding, not a broadcast-accurate decoder.
///
/// Uses [rowStride] (== `plane.bytesPerRow`), not the logical image
/// width, to index into the buffer - a plane's row can be padded wider
/// than its logical pixel width (common on some devices/resolutions), and
/// indexing by logical width instead of the real stride silently reads
/// the wrong bytes for every row past the first.
(int, int, int) _nv21PixelAt(Uint8List bytes, int rowStride, int fullHeight, int x, int y) {
  final frameSize = rowStride * fullHeight;
  final yValue = bytes[y * rowStride + x] & 0xff;
  final uvRowStart = frameSize + (y >> 1) * rowStride;
  final uvCol = (x >> 1) * 2;
  final v = bytes[uvRowStart + uvCol] & 0xff;
  final u = bytes[uvRowStart + uvCol + 1] & 0xff;
  final r = (yValue + 1.370705 * (v - 128)).round().clamp(0, 255);
  final g = (yValue - 0.337633 * (u - 128) - 0.698001 * (v - 128)).round().clamp(0, 255);
  final b = (yValue + 1.732446 * (u - 128)).round().clamp(0, 255);
  return (r, g, b);
}

(int, int, int) _bgraPixelAt(Uint8List bytes, int bytesPerRow, int x, int y) {
  final offset = y * bytesPerRow + x * 4;
  return (bytes[offset + 2], bytes[offset + 1], bytes[offset]);
}
