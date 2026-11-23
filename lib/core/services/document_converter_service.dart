import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/conversion.dart';
import '../models/scanned_file.dart';
import '../utils/formatters.dart';
import 'office_converter.dart';
import 'pdf_converter.dart';

/// Single entry point the converter UI talks to. It validates input, routes to
/// the right engine and returns the produced files, so swapping in a backend for
/// Office files never touches the widgets.
class DocumentConverterService {
  DocumentConverterService({
    required PdfConverter pdf,
    required OfficeConverter office,
  }) : _pdf = pdf,
       _office = office;

  final PdfConverter _pdf;
  final OfficeConverter _office;
  final Uuid _uuid = const Uuid();

  bool get isOfficeAvailable => _office.isAvailable;

  String get officeNote => _office.availabilityNote;

  Future<ConversionResult> convert({
    required ConversionMode mode,
    required List<String> inputPaths,
    required PdfQuality quality,
    required Directory outputDir,
    void Function(double progress)? onProgress,
  }) async {
    if (inputPaths.isEmpty) {
      throw const ConversionException('Choose at least one file to convert.');
    }

    switch (mode) {
      case ConversionMode.imagesToPdf:
        _requireAll(inputPaths, const {FileKind.image});
        final outputPath = p.join(
          outputDir.path,
          'converted_${Formatters.fileStamp(DateTime.now())}.pdf',
        );
        final path = await _pdf.imagesToPdf(
          imagePaths: inputPaths,
          outputPath: outputPath,
          quality: quality,
          onProgress: onProgress,
        );
        return ConversionResult(
          artifacts: [
            ConversionArtifact(
              path: path,
              kind: FileKind.pdf,
              pageCount: inputPaths.length,
            ),
          ],
        );

      case ConversionMode.pdfToImages:
        if (inputPaths.length != 1) {
          throw const ConversionException('Choose a single PDF to convert.');
        }
        _requireAll(inputPaths, const {FileKind.pdf});
        final artifacts = await _pdf.pdfToImages(
          pdfPath: inputPaths.first,
          outputDir: outputDir,
          quality: quality,
          onProgress: onProgress,
        );
        return ConversionResult(artifacts: artifacts);

      case ConversionMode.officeToPdf:
        if (!_office.isAvailable) {
          throw UnsupportedConversionException(_office.availabilityNote);
        }
        _requireAll(inputPaths, const {FileKind.document, FileKind.spreadsheet});
        final artifacts = <ConversionArtifact>[];
        for (var index = 0; index < inputPaths.length; index++) {
          final input = inputPaths[index];
          final name =
              '${Formatters.baseName(p.basename(input))}_${_uuid.v4().substring(0, 8)}.pdf';
          artifacts.add(
            await _office.convertToPdf(
              inputPath: input,
              outputPath: p.join(outputDir.path, name),
              onProgress: (progress) =>
                  onProgress?.call((index + progress) / inputPaths.length),
            ),
          );
        }
        return ConversionResult(artifacts: artifacts);
    }
  }

  void _requireAll(List<String> paths, Set<FileKind> allowed) {
    for (final path in paths) {
      final kind = fileKindFromPath(path);
      if (!allowed.contains(kind)) {
        throw ConversionException(
          '${p.basename(path)} cannot be converted in this mode.',
        );
      }
    }
  }
}
