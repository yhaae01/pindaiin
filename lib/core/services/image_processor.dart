import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../models/conversion.dart';
import '../models/scan_page.dart';

/// Applies the non-destructive edits of a [ScanPage] and encodes the result.
///
/// The pipeline is baked in one pass at export time:
/// EXIF orientation -> downscale -> rotate -> crop -> filter -> encode.
/// It runs in a background isolate because decoding a 12 MP JPEG blocks the UI
/// for hundreds of milliseconds on mid-range phones.
class ImageProcessor {
  const ImageProcessor();

  /// Caps exported pages at ~3000 px on the long edge: plenty for A4 printing
  /// while keeping memory and PDF size sane.
  static const int maxExportDimension = 3000;

  Future<Uint8List> renderPage(
    ScanPage page, {
    required PdfQuality quality,
    bool asPng = false,
  }) {
    return Isolate.run(() => _renderPageSync(page, quality.jpegQuality, asPng));
  }
}

Uint8List _renderPageSync(ScanPage page, int quality, bool asPng) {
  final file = File(page.imagePath);
  if (!file.existsSync()) {
    throw const ConversionException(
      'A page image is missing. It may have been deleted outside the app.',
    );
  }

  final decoded = img.decodeImage(file.readAsBytesSync());
  if (decoded == null) {
    throw const ConversionException(
      'Unsupported or corrupted image. Use JPG, PNG or WebP.',
    );
  }

  // Baking the EXIF orientation makes rotations predictable (some cameras
  // store orientation in metadata instead of rotating the pixels).
  var image = img.bakeOrientation(decoded);

  final longest = image.width > image.height ? image.width : image.height;
  if (longest > ImageProcessor.maxExportDimension) {
    final scale = ImageProcessor.maxExportDimension / longest;
    image = img.copyResize(
      image,
      width: (image.width * scale).round(),
      height: (image.height * scale).round(),
      interpolation: img.Interpolation.average,
    );
  }

  final turns = page.quarterTurns % 4;
  if (turns != 0) {
    image = img.copyRotate(image, angle: turns * 90);
  }

  if (page.hasCrop) {
    final crop = page.crop;
    final x = (crop.left * image.width).round().clamp(0, image.width - 1);
    final y = (crop.top * image.height).round().clamp(0, image.height - 1);
    final width = (crop.width * image.width).round().clamp(1, image.width - x);
    final height = (crop.height * image.height).round().clamp(1, image.height - y);
    image = img.copyCrop(image, x: x, y: y, width: width, height: height);
  }

  switch (page.filter) {
    case ScanFilter.original:
      break;
    case ScanFilter.grayscale:
      image = img.grayscale(image);
    case ScanFilter.document:
      // Grayscale + contrast is cheap and close to a "scanned document" look.
      image = img.adjustColor(img.grayscale(image), contrast: 1.45);
  }

  if (asPng) return img.encodePng(image);
  return img.encodeJpg(image, quality: quality);
}
