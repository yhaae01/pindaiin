import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfx/pdfx.dart' as pdfx;

import '../models/conversion.dart';
import '../models/scanned_file.dart';
import 'file_storage_service.dart';

/// Raster/PDF conversions executed fully on-device.
abstract class PdfConverter {
  /// Builds a PDF from already-rendered JPEG pages (used by scan export, which
  /// applies crop/filter itself). Returns the written path.
  Future<String> bytesToPdf({
    required List<Uint8List> jpegPages,
    required String outputPath,
    void Function(double progress)? onProgress,
  });

  /// Writes a merged PDF to [outputPath] and returns that path.
  Future<String> imagesToPdf({
    required List<String> imagePaths,
    required String outputPath,
    required PdfQuality quality,
    void Function(double progress)? onProgress,
  });

  Future<List<ConversionArtifact>> pdfToImages({
    required String pdfPath,
    required Directory outputDir,
    required PdfQuality quality,
    void Function(double progress)? onProgress,
  });
}

class LocalPdfConverter implements PdfConverter {
  LocalPdfConverter({required this.storage});

  final FileStorageService storage;

  @override
  Future<String> bytesToPdf({
    required List<Uint8List> jpegPages,
    required String outputPath,
    void Function(double progress)? onProgress,
  }) async {
    if (jpegPages.isEmpty) {
      throw const ConversionException('Add at least one page before exporting.');
    }

    final document = pw.Document(compress: true);

    for (var index = 0; index < jpegPages.length; index++) {
      final bytes = jpegPages[index];
      final size = await Isolate.run(() => _jpegSize(bytes));
      final format = size.width > size.height
          ? PdfPageFormat.a4.landscape
          : PdfPageFormat.a4;

      document.addPage(
        pw.Page(
          pageFormat: format,
          margin: const pw.EdgeInsets.all(12),
          build: (context) => pw.Center(
            child: pw.Image(
              pw.MemoryImage(bytes),
              fit: pw.BoxFit.contain,
            ),
          ),
        ),
      );
      onProgress?.call((index + 1) / jpegPages.length);
    }

    final bytes = await document.save();
    final output = File(outputPath);
    await output.parent.create(recursive: true);
    await output.writeAsBytes(bytes, flush: true);
    return output.path;
  }

  @override
  Future<String> imagesToPdf({
    required List<String> imagePaths,
    required String outputPath,
    required PdfQuality quality,
    void Function(double progress)? onProgress,
  }) async {
    if (imagePaths.isEmpty) {
      throw const ConversionException('Add at least one page before exporting.');
    }

    final preparedPages = <Uint8List>[];
    for (var index = 0; index < imagePaths.length; index++) {
      final path = imagePaths[index];
      if (!File(path).existsSync()) {
        throw ConversionException('Missing image: ${p.basename(path)}');
      }
      // Re-encode each page off the UI thread so memory stays bounded and the
      // PDF embeds JPEG (much smaller than PNG for photos).
      final prepared = await Isolate.run(
        () => _prepareImage(imagePath: path, quality: quality.jpegQuality),
      );
      preparedPages.add(prepared.bytes);
      onProgress?.call(0.6 * (index + 1) / imagePaths.length);
    }

    return bytesToPdf(
      jpegPages: preparedPages,
      outputPath: outputPath,
      onProgress: (progress) => onProgress?.call(0.6 + 0.4 * progress),
    );
  }

  @override
  Future<List<ConversionArtifact>> pdfToImages({
    required String pdfPath,
    required Directory outputDir,
    required PdfQuality quality,
    void Function(double progress)? onProgress,
  }) async {
    final source = File(pdfPath);
    if (!await source.exists()) {
      throw const ConversionException('The PDF could not be found on disk.');
    }

    final document = await pdfx.PdfDocument.openFile(pdfPath);
    final artifacts = <ConversionArtifact>[];
    final base = p.basenameWithoutExtension(pdfPath);

    try {
      // pdfx cannot render pages in parallel on Android, so render serially.
      for (var index = 1; index <= document.pagesCount; index++) {
        final page = await document.getPage(index);
        try {
          final renderWidth = 595 * quality.renderScale;
          final renderHeight = renderWidth * page.height / page.width;

          final rendered = await page.render(
            width: renderWidth,
            height: renderHeight,
            format: pdfx.PdfPageImageFormat.jpeg,
            quality: quality.jpegQuality,
            backgroundColor: '#FFFFFF',
          );
          if (rendered == null) {
            throw ConversionException('Page $index could not be rendered.');
          }

          final name = '$base-page-${index.toString().padLeft(2, '0')}.jpg';
          final path = await storage.writeBytes(
            directory: outputDir,
            fileName: name,
            bytes: rendered.bytes,
          );
          artifacts.add(ConversionArtifact(path: path, kind: FileKind.image));
        } finally {
          await page.close();
        }

        onProgress?.call(index / document.pagesCount);
      }
    } finally {
      await document.close();
    }

    return artifacts;
  }
}

/// Reads just the header dimensions of an encoded JPEG.
({int width, int height}) _jpegSize(Uint8List bytes) {
  final decoded = img.JpegDecoder().startDecode(bytes);
  if (decoded == null) {
    throw const ConversionException('Could not read a rendered page.');
  }
  return (width: decoded.width, height: decoded.height);
}

/// Decodes, bakes orientation, bounds the resolution and re-encodes to JPEG.
class PreparedImage {
  const PreparedImage({required this.bytes, required this.width, required this.height});

  final Uint8List bytes;
  final int width;
  final int height;
}

PreparedImage _prepareImage({required String imagePath, required int quality}) {
  final decoded = img.decodeImage(File(imagePath).readAsBytesSync());
  if (decoded == null) {
    throw const ConversionException('Unsupported image format.');
  }
  var image = img.bakeOrientation(decoded);
  const maxDimension = 3500;
  final longest = image.width > image.height ? image.width : image.height;
  if (longest > maxDimension) {
    final scale = maxDimension / longest;
    image = img.copyResize(
      image,
      width: (image.width * scale).round(),
      height: (image.height * scale).round(),
      interpolation: img.Interpolation.average,
    );
  }
  return PreparedImage(
    bytes: img.encodeJpg(image, quality: quality),
    width: image.width,
    height: image.height,
  );
}
