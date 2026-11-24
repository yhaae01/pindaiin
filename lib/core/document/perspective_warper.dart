import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:image/image.dart' as img;

import '../models/conversion.dart';
import 'document_corners.dart';
import 'perspective_transform.dart';

/// Rectifies the detected page into a straight, cropped image.
///
/// The interface is deliberately small so the implementation can be swapped
/// (pure Dart here, native/GPU later) without touching the scanner UI.
abstract interface class PerspectiveWarper {
  /// [corners] are normalized to the image *after* [quarterTurns] are applied.
  Future<Uint8List> warp({
    required Uint8List sourceBytes,
    required DocumentCorners corners,
    int quarterTurns = 0,
    int maxDimension,
    int jpegQuality,
  });
}

/// Homography-based deskew in pure Dart.
///
/// The four corners define a projective transform from the output rectangle to
/// the source image; every output pixel is sampled bilinearly from the source.
/// Straight lines stay straight, which is what removes the skew of a photo
/// taken at an angle.
class HomographyPerspectiveWarper implements PerspectiveWarper {
  const HomographyPerspectiveWarper({
    this.defaultMaxDimension = 2600,
    this.defaultJpegQuality = 92,
    this.maxInputDimension = 4200,
  });

  /// Working copies stay below this so editing stays fast on mid-range phones
  /// while A4 pages still print well.
  final int defaultMaxDimension;
  final int defaultJpegQuality;

  /// Big inputs are downscaled before warping; the source limit avoids
  /// decoding 100 MP photos at full size.
  final int maxInputDimension;

  @override
  Future<Uint8List> warp({
    required Uint8List sourceBytes,
    required DocumentCorners corners,
    int quarterTurns = 0,
    int maxDimension = 0,
    int jpegQuality = 0,
  }) {
    final quad = <double>[
      for (final point in corners.points) ...[point.dx, point.dy],
    ];
    final output = maxDimension > 0 ? maxDimension : defaultMaxDimension;
    final quality = jpegQuality > 0 ? jpegQuality : defaultJpegQuality;
    final inputLimit = maxInputDimension;
    return Isolate.run(
      () => warpDocumentPerspective(
        sourceBytes,
        quad: quad,
        quarterTurns: quarterTurns,
        maxDimension: output,
        jpegQuality: quality,
        maxInputDimension: inputLimit,
      ),
    );
  }
}

/// Synchronous warp used inside an isolate and by tests.
///
/// [quad] is `[tlX, tlY, trX, trY, brX, brY, blX, blY]` in normalized
/// coordinates of the rotated source frame.
Uint8List warpDocumentPerspective(
  Uint8List sourceBytes, {
  required List<double> quad,
  int quarterTurns = 0,
  int maxDimension = 2600,
  int jpegQuality = 92,
  int maxInputDimension = 4200,
}) {
  if (quad.length != 8) {
    throw const ConversionException('The page outline is incomplete.');
  }

  final decoded = img.decodeImage(sourceBytes);
  if (decoded == null) {
    throw const ConversionException(
      'Unsupported or corrupted image. Use JPG, PNG or WebP.',
    );
  }

  img.Image image;
  try {
    image = img.bakeOrientation(decoded);
  } catch (_) {
    image = decoded;
  }

  final longestInput = math.max(image.width, image.height);
  if (longestInput > maxInputDimension) {
    final scale = maxInputDimension / longestInput;
    image = img.copyResize(
      image,
      width: math.max(1, (image.width * scale).round()),
      height: math.max(1, (image.height * scale).round()),
      interpolation: img.Interpolation.average,
    );
  }

  final turns = quarterTurns % 4;
  if (turns != 0) {
    image = img.copyRotate(image, angle: turns * 90);
  }

  final width = image.width;
  final height = image.height;
  final corners = DocumentCorners(
    topLeft: _pixel(quad[0], quad[1], width, height),
    topRight: _pixel(quad[2], quad[3], width, height),
    bottomRight: _pixel(quad[4], quad[5], width, height),
    bottomLeft: _pixel(quad[6], quad[7], width, height),
  );

  if (!corners.isValid) {
    throw const ConversionException(
      'The page outline is invalid. Adjust the four corners and try again.',
    );
  }

  // Output size follows the longest opposite edges, so the rectified page keeps
  // its real proportions.
  final top = (corners.topRight - corners.topLeft).distance;
  final bottom = (corners.bottomRight - corners.bottomLeft).distance;
  final left = (corners.bottomLeft - corners.topLeft).distance;
  final right = (corners.bottomRight - corners.topRight).distance;

  var outputWidth = math.max(top, bottom).round();
  var outputHeight = math.max(left, right).round();
  if (outputWidth < 16 || outputHeight < 16) {
    throw const ConversionException('The page outline is too small.');
  }

  final outputLongest = math.max(outputWidth, outputHeight);
  if (outputLongest > maxDimension) {
    final scale = maxDimension / outputLongest;
    outputWidth = math.max(1, (outputWidth * scale).round());
    outputHeight = math.max(1, (outputHeight * scale).round());
  }

  final transform = ProjectiveTransform.unitSquareTo(corners.points);
  final rgb = image.getBytes(order: img.ChannelOrder.rgb);
  final rowStride = width * 3;
  final output = Uint8List(outputWidth * outputHeight * 3);
  final matrix = transform.matrix;

  var destination = 0;
  for (var y = 0; y < outputHeight; y++) {
    final v = (y + 0.5) / outputHeight;
    for (var x = 0; x < outputWidth; x++) {
      final u = (x + 0.5) / outputWidth;

      final denominator = matrix[6] * u + matrix[7] * v + matrix[8];
      var sourceX = (matrix[0] * u + matrix[1] * v + matrix[2]) / denominator;
      var sourceY = (matrix[3] * u + matrix[4] * v + matrix[5]) / denominator;

      if (sourceX < 0) {
        sourceX = 0;
      } else if (sourceX > width - 1) {
        sourceX = (width - 1).toDouble();
      }
      if (sourceY < 0) {
        sourceY = 0;
      } else if (sourceY > height - 1) {
        sourceY = (height - 1).toDouble();
      }

      final x0 = sourceX.floor();
      final y0 = sourceY.floor();
      final x1 = math.min(x0 + 1, width - 1);
      final y1 = math.min(y0 + 1, height - 1);
      final fx = sourceX - x0;
      final fy = sourceY - y0;

      final topLeftIndex = y0 * rowStride + x0 * 3;
      final topRightIndex = y0 * rowStride + x1 * 3;
      final bottomLeftIndex = y1 * rowStride + x0 * 3;
      final bottomRightIndex = y1 * rowStride + x1 * 3;

      for (var channel = 0; channel < 3; channel++) {
        final topValue =
            rgb[topLeftIndex + channel] +
            (rgb[topRightIndex + channel] - rgb[topLeftIndex + channel]) * fx;
        final bottomValue =
            rgb[bottomLeftIndex + channel] +
            (rgb[bottomRightIndex + channel] - rgb[bottomLeftIndex + channel]) *
                fx;
        final value = (topValue + (bottomValue - topValue) * fy).round();
        output[destination + channel] = value < 0
            ? 0
            : value > 255
            ? 255
            : value;
      }
      destination += 3;
    }
  }

  final warped = img.Image.fromBytes(
    width: outputWidth,
    height: outputHeight,
    bytes: output.buffer,
    numChannels: 3,
  );
  return img.encodeJpg(warped, quality: jpegQuality);
}

Offset _pixel(double normalizedX, double normalizedY, int width, int height) {
  return Offset(
    (normalizedX * width).clamp(0.0, (width - 1).toDouble()),
    (normalizedY * height).clamp(0.0, (height - 1).toDouble()),
  );
}
