import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';

import '../../../core/document/luma_frame.dart';

/// Converts a streamed [CameraImage] to a small grayscale frame.
///
/// The camera plugin delivers YUV420 (Android) or BGRA8888 (iOS) planes, both in
/// sensor orientation. Only luminance is needed for edge detection, so this
/// avoids JPEG decoding entirely and resamples while copying. No camera-specific
/// types leak into the document pipeline ([LumaFrame] is pure Dart).
LumaFrame? lumaFrameFromCameraImage(
  CameraImage image, {
  int targetLongest = 400,
}) {
  final width = image.width;
  final height = image.height;
  if (width <= 0 || height <= 0 || image.planes.isEmpty) return null;

  final longest = math.max(width, height);
  final scale = longest > targetLongest ? targetLongest / longest : 1.0;
  final targetWidth = math.max(1, (width * scale).round());
  final targetHeight = math.max(1, (height * scale).round());

  final group = image.format.group;
  if (group == ImageFormatGroup.bgra8888) {
    return _fromBgra(image, targetWidth, targetHeight);
  }
  if (group == ImageFormatGroup.yuv420 ||
      group == ImageFormatGroup.nv21 ||
      image.planes.length >= 3) {
    return _fromYPlane(image, targetWidth, targetHeight);
  }

  // Unknown format: a single plane with one byte per pixel is already luma
  // (e.g. NV21 on devices that report `unknown`).
  final plane = image.planes.first;
  final pixelStride = plane.bytesPerPixel ?? 1;
  if (image.planes.length == 1 && pixelStride == 4) {
    return _fromBgra(image, targetWidth, targetHeight);
  }
  if (image.planes.length == 1) {
    return _fromYPlane(image, targetWidth, targetHeight);
  }
  return null;
}

LumaFrame? _fromYPlane(CameraImage image, int targetWidth, int targetHeight) {
  final plane = image.planes.first;
  final bytes = plane.bytes;
  final sourceWidth = image.width;
  final sourceHeight = image.height;
  final rowStride = plane.bytesPerRow;
  final pixelStride = math.max(1, plane.bytesPerPixel ?? 1);

  if (rowStride < sourceWidth) return null;

  final output = Uint8List(targetWidth * targetHeight);
  for (var y = 0; y < targetHeight; y++) {
    final sourceY = math.min(
      sourceHeight - 1,
      (y * sourceHeight / targetHeight).floor(),
    );
    final sourceRow = sourceY * rowStride;
    final targetRow = y * targetWidth;
    for (var x = 0; x < targetWidth; x++) {
      final sourceX = math.min(
        sourceWidth - 1,
        (x * sourceWidth / targetWidth).floor(),
      );
      final index = sourceRow + sourceX * pixelStride;
      if (index < bytes.length) {
        output[targetRow + x] = bytes[index];
      }
    }
  }
  return LumaFrame(width: targetWidth, height: targetHeight, bytes: output);
}

LumaFrame? _fromBgra(CameraImage image, int targetWidth, int targetHeight) {
  final plane = image.planes.first;
  final bytes = plane.bytes;
  final sourceWidth = image.width;
  final sourceHeight = image.height;
  final rowStride = plane.bytesPerRow;
  final pixelStride = math.max(3, plane.bytesPerPixel ?? 4);

  final output = Uint8List(targetWidth * targetHeight);
  for (var y = 0; y < targetHeight; y++) {
    final sourceY = math.min(
      sourceHeight - 1,
      (y * sourceHeight / targetHeight).floor(),
    );
    final sourceRow = sourceY * rowStride;
    final targetRow = y * targetWidth;
    for (var x = 0; x < targetWidth; x++) {
      final sourceX = math.min(
        sourceWidth - 1,
        (x * sourceWidth / targetWidth).floor(),
      );
      final index = sourceRow + sourceX * pixelStride;
      if (index + 2 < bytes.length) {
        final blue = bytes[index];
        final green = bytes[index + 1];
        final red = bytes[index + 2];
        output[targetRow + x] = (77 * red + 150 * green + 29 * blue) >> 8;
      }
    }
  }
  return LumaFrame(width: targetWidth, height: targetHeight, bytes: output);
}
