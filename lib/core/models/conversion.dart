import 'package:path/path.dart' as p;

import 'scanned_file.dart';

/// Shared quality presets for both export directions.
enum PdfQuality {
  low('Low', 'Smallest files', 45, 1.0),
  balanced('Balanced', 'Good quality / size ratio', 70, 1.5),
  high('High', 'Best quality, largest files', 90, 2.0);

  const PdfQuality(this.label, this.description, this.jpegQuality, this.renderScale);

  final String label;
  final String description;

  /// JPEG quality used when writing images (scan export + PDF rasterisation).
  final int jpegQuality;

  /// Multiplier applied to PDF page dimensions when rendering PDF -> images.
  final double renderScale;
}

/// Target of an Office conversion. Also declares which inputs are valid so the
/// UI and the repository validate the same rules.
enum OfficeTarget {
  pdf(
    'PDF',
    'pdf',
    'application/pdf',
    FileKind.pdf,
    ['doc', 'docx', 'odt', 'rtf', 'xls', 'xlsx', 'csv'],
  ),
  docx(
    'Word',
    'docx',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    FileKind.document,
    ['pdf'],
  ),
  xlsx(
    'Excel',
    'xlsx',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    FileKind.spreadsheet,
    ['pdf'],
  );

  const OfficeTarget(
    this.label,
    this.extension,
    this.mimeType,
    this.artifactKind,
    this.sourceExtensions,
  );

  final String label;
  final String extension;
  final String mimeType;
  final FileKind artifactKind;
  final List<String> sourceExtensions;

  bool acceptsPath(String path) =>
      sourceExtensions.contains(p.extension(path).toLowerCase().replaceFirst('.', ''));
}

/// Conversions the UI can request. Office modes are routed to the pluggable
/// [OfficeConverter] repository so a backend can be wired in without UI changes.
enum ConversionMode {
  imagesToPdf,
  pdfToImages,
  officeToPdf,
  pdfToWord,
  pdfToExcel;

  String get label => switch (this) {
    ConversionMode.imagesToPdf => 'Images → PDF',
    ConversionMode.pdfToImages => 'PDF → Images',
    ConversionMode.officeToPdf => 'Office → PDF',
    ConversionMode.pdfToWord => 'PDF → Word',
    ConversionMode.pdfToExcel => 'PDF → Excel',
  };

  bool get isOffice => officeTarget != null;

  OfficeTarget? get officeTarget => switch (this) {
    ConversionMode.officeToPdf => OfficeTarget.pdf,
    ConversionMode.pdfToWord => OfficeTarget.docx,
    ConversionMode.pdfToExcel => OfficeTarget.xlsx,
    _ => null,
  };
}

/// Progress update with an optional human-readable stage ("Uploading…").
class ConversionProgress {
  const ConversionProgress(this.fraction, [this.label]);

  final double fraction;
  final String? label;
}

class ConversionArtifact {
  const ConversionArtifact({
    required this.path,
    required this.kind,
    this.pageCount,
  });

  final String path;
  final FileKind kind;
  final int? pageCount;
}

class ConversionResult {
  const ConversionResult({required this.artifacts});


  final List<ConversionArtifact> artifacts;
}

/// User-facing conversion failure. Controllers surface [message] directly.
class ConversionException implements Exception {
  const ConversionException(this.message);

  final String message;

  @override
  String toString() => message;
}

class UnsupportedConversionException extends ConversionException {
  const UnsupportedConversionException(super.message);
}
