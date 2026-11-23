import '../models/conversion.dart';

/// DOCX/XLSX -> PDF needs a rendering engine (LibreOffice) that does not fit on
/// a mobile device. This interface keeps the UI/controllers unaware of where the
/// work happens, so a backend can be plugged in later.
///
/// A production implementation would:
///  1. upload the file to an endpoint with a signed URL,
///  2. poll or wait on a webhook for completion,
///  3. download the resulting PDF to [outputPath],
///  4. report progress through [onProgress].
abstract class OfficeConverter {
  bool get isAvailable;

  /// Explains why the feature is disabled; shown as a banner in the converter.
  String get availabilityNote;

  Future<ConversionArtifact> convertToPdf({
    required String inputPath,
    required String outputPath,
    void Function(double progress)? onProgress,
  });
}

class UnavailableOfficeConverter implements OfficeConverter {
  const UnavailableOfficeConverter();

  static const message =
      'Office conversions need a backend service. Images ↔ PDF work offline '
      'right now; connect an OfficeConverter to enable DOCX/XLSX → PDF.';

  @override
  bool get isAvailable => false;

  @override
  String get availabilityNote => message;

  @override
  Future<ConversionArtifact> convertToPdf({
    required String inputPath,
    required String outputPath,
    void Function(double progress)? onProgress,
  }) async {
    throw const UnsupportedConversionException(message);
  }
}
