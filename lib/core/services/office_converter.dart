import '../models/conversion.dart';
import 'office/office_conversion_models.dart';

/// DOCX/XLSX <-> PDF requires a dedicated rendering engine, so the work is
/// delegated to an [OfficeConversionRepository] (REST backend or mock).
///
/// The rest of the app only depends on this interface; replacing the backend
/// never changes UI code.
abstract class OfficeConverter {
  bool get isAvailable;

  /// True when outputs come from the local mock instead of a real renderer.
  bool get isDemo;

  /// Human-readable backend identifier shown in the converter UI.
  String get backendLabel;

  /// Explains limitations (demo mode or a disabled feature).
  String get availabilityNote;

  Future<ConversionArtifact> convert({
    required String inputPath,
    required String outputPath,
    required OfficeTarget target,
    OfficeProgressCallback? onProgress,
  });
}
