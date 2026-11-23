import 'dart:io';

import 'package:path/path.dart' as p;

import '../../models/conversion.dart';
import '../office_converter.dart';
import 'office_conversion_models.dart';
import 'office_conversion_repository.dart';

/// Validates the picked file, calls the configured backend and writes the
/// returned bytes into the app's exports folder.
class RepositoryOfficeConverter implements OfficeConverter {
  RepositoryOfficeConverter({required this.repository});

  final OfficeConversionRepository repository;

  @override
  bool get isAvailable => true;

  @override
  bool get isDemo => !repository.isRemote;

  @override
  String get backendLabel => repository.backendLabel;

  @override
  String get availabilityNote => isDemo
      ? 'Demo converter: outputs are placeholder files. Set OFFICE_API_URL to '
            'connect a real rendering backend.'
      : 'Conversion runs on ${repository.backendLabel}. Files are uploaded, '
            'converted, then downloaded again.';

  @override
  Future<ConversionArtifact> convert({
    required String inputPath,
    required String outputPath,
    required OfficeTarget target,
    OfficeProgressCallback? onProgress,
  }) async {
    final fileName = p.basename(inputPath);

    // Validate before touching the network.
    if (!target.acceptsPath(inputPath)) {
      throw OfficeConversionException(
        OfficeErrorCode.unsupportedFormat,
        '${target.label} conversion accepts ${target.sourceExtensions.join(', ').toUpperCase()} files only.',
      );
    }

    final source = File(inputPath);
    final size = await source.exists() ? await source.length() : 0;
    if (size == 0) {
      throw const OfficeConversionException(
        OfficeErrorCode.emptyFile,
        'The selected file is empty or no longer available.',
      );
    }
    if (size > repository.maxUploadBytes) {
      throw OfficeConversionException(
        OfficeErrorCode.fileTooLarge,
        'The file is larger than the ${_mb(repository.maxUploadBytes)} MB upload limit.',
      );
    }

    onProgress?.call(const OfficeProgress(OfficeConversionStage.validating, 0));

    final response = await repository.convert(
      OfficeConversionRequest(
        inputPath: inputPath,
        inputFileName: fileName,
        inputSizeBytes: size,
        target: target,
      ),
      onProgress: onProgress,
    );

    if (response.bytes.isEmpty) {
      throw const OfficeConversionException(
        OfficeErrorCode.invalidResponse,
        'The conversion service returned an empty file.',
      );
    }

    onProgress?.call(const OfficeProgress(OfficeConversionStage.saving, 0.95));

    final output = File(outputPath);
    await output.parent.create(recursive: true);
    await output.writeAsBytes(response.bytes, flush: true);

    onProgress?.call(const OfficeProgress(OfficeConversionStage.saving, 1));
    return ConversionArtifact(path: output.path, kind: target.artifactKind);
  }
}

String _mb(int bytes) => (bytes / (1024 * 1024)).round().toString();
