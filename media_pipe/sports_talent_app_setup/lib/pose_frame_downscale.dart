import 'dart:typed_data';

import 'package:camera/camera.dart';

/// Downscales a raw camera frame (NV21 on Android / BGRA8888 on iOS,
/// single-plane - matching the assumptions already made throughout this
/// app's camera pipeline) by an integer [factor] via simple
/// nearest-neighbor pixel decimation (no interpolation - cheap enough to
/// run on every processed frame).
///
/// Exists so the continuous pose-detection pipeline can keep operating on
/// a small image after the camera stream itself was raised to
/// `ResolutionPreset.high` for face-verification's benefit, without a
/// second camera controller and without resizing/re-encoding the frame
/// (just striding over the existing bytes). Identity/face-verification
/// code never calls this - it always uses the original, undownscaled
/// [CameraImage] directly.
class DownscaledFrame {
  const DownscaledFrame({
    required this.bytes,
    required this.width,
    required this.height,
    required this.bytesPerRow,
  });

  final Uint8List bytes;
  final int width;
  final int height;
  final int bytesPerRow;
}

/// Returns null for unsupported formats/plane layouts (same constraints
/// as the rest of the app's raw-frame handling) or a non-positive
/// [factor].
DownscaledFrame? downscaleCameraImage(CameraImage image, int factor) {
  if (factor <= 1) return null;
  if (image.planes.length != 1) return null;
  final plane = image.planes.first;
  switch (image.format.group) {
    case ImageFormatGroup.nv21:
      return _downscaleNv21(
        plane.bytes,
        plane.bytesPerRow,
        image.width,
        image.height,
        factor,
      );
    case ImageFormatGroup.bgra8888:
      return _downscaleBgra8888(plane.bytes, plane.bytesPerRow, image.width, image.height, factor);
    default:
      return null;
  }
}

/// Decimates a single-plane NV21 buffer (Y plane + interleaved VU plane).
/// Strides by whole 2x2 chroma blocks (both destination dimensions forced
/// even), so the output is itself a valid, tightly-packed NV21 buffer -
/// not an approximation that happens to look right. Uses [srcRowStride]
/// (== `plane.bytesPerRow`), not [srcWidth], to index into the source
/// buffer - a plane's row can be padded wider than its logical pixel
/// width (see face_image_utils.dart's identical concern for the
/// face-verification path), but [srcWidth] (the true pixel width) is what
/// determines the output size.
DownscaledFrame _downscaleNv21(
  Uint8List src,
  int srcRowStride,
  int srcWidth,
  int srcHeight,
  int factor,
) {
  final dstWidth = ((srcWidth ~/ factor) ~/ 2) * 2;
  final dstHeight = ((srcHeight ~/ factor) ~/ 2) * 2;
  final ySize = dstWidth * dstHeight;
  final out = Uint8List(ySize + ySize ~/ 2);
  final srcFrameSize = srcRowStride * srcHeight;

  for (var y = 0; y < dstHeight; y++) {
    final srcRowOffset = (y * factor) * srcRowStride;
    final dstRowOffset = y * dstWidth;
    for (var x = 0; x < dstWidth; x++) {
      out[dstRowOffset + x] = src[srcRowOffset + x * factor];
    }
  }

  final dstChromaCols = dstWidth ~/ 2;
  final dstChromaRows = dstHeight ~/ 2;
  var outUvOffset = ySize;
  for (var cy = 0; cy < dstChromaRows; cy++) {
    final srcUvRowStart = srcFrameSize + (cy * factor) * srcRowStride;
    for (var cx = 0; cx < dstChromaCols; cx++) {
      final srcCol = (cx * factor) * 2;
      out[outUvOffset++] = src[srcUvRowStart + srcCol];
      out[outUvOffset++] = src[srcUvRowStart + srcCol + 1];
    }
  }

  return DownscaledFrame(bytes: out, width: dstWidth, height: dstHeight, bytesPerRow: dstWidth);
}

DownscaledFrame _downscaleBgra8888(
  Uint8List src,
  int srcBytesPerRow,
  int srcWidth,
  int srcHeight,
  int factor,
) {
  final dstWidth = srcWidth ~/ factor;
  final dstHeight = srcHeight ~/ factor;
  final dstBytesPerRow = dstWidth * 4;
  final out = Uint8List(dstBytesPerRow * dstHeight);
  for (var y = 0; y < dstHeight; y++) {
    final srcRowOffset = (y * factor) * srcBytesPerRow;
    final dstRowOffset = y * dstBytesPerRow;
    for (var x = 0; x < dstWidth; x++) {
      final srcOffset = srcRowOffset + (x * factor) * 4;
      final dstOffset = dstRowOffset + x * 4;
      out[dstOffset] = src[srcOffset];
      out[dstOffset + 1] = src[srcOffset + 1];
      out[dstOffset + 2] = src[srcOffset + 2];
      out[dstOffset + 3] = src[srcOffset + 3];
    }
  }
  return DownscaledFrame(
    bytes: out,
    width: dstWidth,
    height: dstHeight,
    bytesPerRow: dstBytesPerRow,
  );
}
