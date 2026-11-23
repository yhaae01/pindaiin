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
    required this.pdf,
    required this.office,
  });

  final PdfConverter pdf;
  final OfficeConverter office;
  final Uuid _uuid = const Uuid();

  bool get isOfficeAvailable => office.isAvailable;

  bool get isOfficeDemo => office.isDemo;

  String get officeNote => office.availabilityNote;

  String get officeBackendLabel => office.backendLabel;

  Future<ConversionResult> convert({
    required ConversionMode mode,
    required List<String> inputPaths,
    required PdfQuality quality,
    required Directory outputDir,
    void Function(ConversionProgress progress)? onProgress,
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
        final path = await pdf.imagesToPdf(
          imagePaths: inputPaths,
          outputPath: outputPath,
          quality: quality,
          onProgress: (fraction) => onProgress?.call(
            ConversionProgress(0.8 * fraction, 'Building PDF…'),
          ),
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
        final artifacts = await pdf.pdfToImages(
          pdfPath: inputPaths.first,
          outputDir: outputDir,
          quality: quality,
          onProgress: (fraction) => onProgress?.call(
            ConversionProgress(fraction, 'Rendering pages…'),
          ),
        );
        return ConversionResult(artifacts: artifacts);

      case ConversionMode.officeToPdf:
      case ConversionMode.pdfToWord:
      case ConversionMode.pdfToExcel:
        return _convertOffice(
          mode: mode,
          inputPaths: inputPaths,
          outputDir: outputDir,
          onProgress: onProgress,
        );
    }
  }

  Future<ConversionResult> _convertOffice({
    required ConversionMode mode,
    required List<String> inputPaths,
    required Directory outputDir,
    void Function(ConversionProgress progress)? onProgress,
  }) async {
    final target = mode.officeTarget!;

    if (!office.isAvailable) {
      throw UnsupportedConversionException(office.availabilityNote);
    }

    if (target == OfficeTarget.pdf) {
      _requireAll(inputPaths, const {FileKind.document, FileKind.spreadsheet});
    } else {
      _requireAll(inputPaths, const {FileKind.pdf});
    }

    final artifacts = <ConversionArtifact>[];
    for (var index = 0; index < inputPaths.length; index++) {
      final input = inputPaths[index];
      final name =
          '${Formatters.baseName(p.basename(input))}_${_uuid.v4().substring(0, 8)}.${target.extension}';

      artifacts.add(
        await office.convert(
          inputPath: input,
          outputPath: p.join(outputDir.path, name),
          target: target,
          onProgress: (event) {
            final withinFile = event.fraction ?? 0;
            onProgress?.call(
              ConversionProgress(
                (index + withinFile) / inputPaths.length,
                event.stage.label,
              ),
            );
          },
        ),
      );
    }

    return ConversionResult(artifacts: artifacts);
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
