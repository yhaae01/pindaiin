import 'dart:typed_data';

import '../../models/conversion.dart';

/// Which stage a progress event belongs to. The UI can show a precise label
/// instead of a generic spinner during large uploads.
enum OfficeConversionStage {
  validating('Checking file…'),
  uploading('Uploading…'),
  converting('Converting on server…'),
  downloading('Downloading result…'),
  saving('Saving…');

  const OfficeConversionStage(this.label);
  final String label;
}

class OfficeProgress {
  const OfficeProgress(this.stage, this.fraction);

  final OfficeConversionStage stage;

  /// Overall progress 0..1, or null when the server did not report a total.
  final double? fraction;
}

typedef OfficeProgressCallback = void Function(OfficeProgress progress);

class OfficeConversionRequest {
  const OfficeConversionRequest({
    required this.inputPath,
    required this.inputFileName,
    required this.inputSizeBytes,
    required this.target,
  });

  final String inputPath;
  final String inputFileName;
  final int inputSizeBytes;
  final OfficeTarget target;
}

class OfficeConversionResponse {
  const OfficeConversionResponse({
    required this.bytes,
    this.serverFileName,
    this.jobId,
  });

  final Uint8List bytes;
  final String? serverFileName;

  /// Populated when the backend echoes `X-Conversion-Id`.
  final String? jobId;
}

enum OfficeErrorCode {
  unsupportedFormat,
  fileTooLarge,
  emptyFile,
  network,
  timeout,
  server,
  invalidResponse,
  cancelled,
  unavailable,
  unknown,
}

/// Structured failure carrying a code the UI could branch on later and a
/// message that is safe to display to the user.
class OfficeConversionException implements Exception {
  const OfficeConversionException(
    this.code,
    this.message, {
    this.retryable = false,
  });

  final OfficeErrorCode code;
  final String message;
  final bool retryable;

  @override
  String toString() => message;
}

/// Server response shape for non-2xx replies:
/// `{"error": {"code": "unsupported_format", "message": "..."}}`
class OfficeApiErrorBody {
  const OfficeApiErrorBody({required this.code, required this.message});

  final String code;
  final String message;
}
