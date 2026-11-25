import 'dart:typed_data';

/// One grayscale camera frame: [width] × [height] bytes, row-major.
///
/// Live detection runs on luminance only; decoding a full JPEG/YUV frame per
/// preview frame would be wasteful. Camera-specific conversion (YUV420, NV21,
/// BGRA8888) lives in the scanner layer, so the document pipeline stays
/// independent of the camera plugin.
class LumaFrame {
  const LumaFrame({
    required this.width,
    required this.height,
    required this.bytes,
  });

  final int width;
  final int height;
  final Uint8List bytes;

  bool get isValid =>
      width > 0 && height > 0 && bytes.length >= width * height;
}
