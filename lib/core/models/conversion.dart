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

/// Conversions the UI can request. `officeToPdf` is routed to the pluggable
/// [OfficeConverter] so a backend can be wired in later without UI changes.
enum ConversionMode {
  imagesToPdf,
  pdfToImages,
  officeToPdf;

  String get label => switch (this) {
    ConversionMode.imagesToPdf => 'Images → PDF',
    ConversionMode.pdfToImages => 'PDF → Images',
    ConversionMode.officeToPdf => 'Office → PDF',
  };
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
