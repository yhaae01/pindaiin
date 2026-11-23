import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import 'office_conversion_models.dart';
import 'office_conversion_repository.dart';

/// Talks to a self-hosted conversion backend.
///
/// Contract: `POST /v1/office/convert` as `multipart/form-data` with a `file`
/// part and a `target` field (`pdf` | `docx` | `xlsx`). A successful response is
/// the converted binary (`Content-Type` matching the target); errors are JSON
/// `{"error": {"code": "...", "message": "..."}}`.
/// See `docs/office-conversion-api.md` for the full specification.
class RestOfficeConversionRepository implements OfficeConversionRepository {
  RestOfficeConversionRepository({
    required String baseUrl,
    this.apiKey,
    Dio? dio,
    this.maxUploadBytes = 25 * 1024 * 1024,
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               baseUrl: baseUrl.endsWith('/')
                   ? baseUrl.substring(0, baseUrl.length - 1)
                   : baseUrl,
               connectTimeout: const Duration(seconds: 20),
               sendTimeout: const Duration(minutes: 3),
               receiveTimeout: const Duration(minutes: 3),
               responseType: ResponseType.bytes,
             ),
           );

  final Dio _dio;
  final String? apiKey;

  @override
  final int maxUploadBytes;

  @override
  bool get isRemote => true;

  @override
  String get backendLabel => Uri.parse(_dio.options.baseUrl).host;

  @override
  Future<OfficeConversionResponse> convert(
    OfficeConversionRequest request, {
    OfficeProgressCallback? onProgress,
  }) async {
    final form = FormData.fromMap({
      'target': request.target.name,
      'file': await MultipartFile.fromFile(
        request.inputPath,
        filename: request.inputFileName,
        contentType: DioMediaType(
          'application',
          _inputMime(request.inputFileName),
        ),
      ),
    });

    onProgress?.call(const OfficeProgress(OfficeConversionStage.uploading, 0));

    try {
      final response = await _dio.post<List<int>>(
        '/v1/office/convert',
        data: form,
        options: Options(
          responseType: ResponseType.bytes,
          headers: {
            'Accept': request.target.mimeType,
            if (apiKey != null) 'Authorization': 'Bearer $apiKey',
          },
        ),
        onSendProgress: (sent, total) {
          if (total <= 0) return;
          // Upload is 0..0.7; server work + download follow, and the adapter
          // reports 0.95..1.0 while saving.
          onProgress?.call(
            OfficeProgress(OfficeConversionStage.uploading, 0.7 * sent / total),
          );
        },
        onReceiveProgress: (received, total) {
          if (total <= 0) return;
          onProgress?.call(
            OfficeProgress(
              OfficeConversionStage.downloading,
              0.8 + 0.15 * received / total,
            ),
          );
        },
      );

      final data = response.data;
      if (data == null || data.isEmpty) {
        throw const OfficeConversionException(
          OfficeErrorCode.invalidResponse,
          'The server returned an empty file.',
        );
      }

      final contentType = response.headers.value(Headers.contentTypeHeader);
      if (contentType != null &&
          !contentType.contains(request.target.mimeType) &&
          !contentType.contains('application/octet-stream')) {
        throw const OfficeConversionException(
          OfficeErrorCode.invalidResponse,
          'The server returned an unexpected file type.',
        );
      }

      return OfficeConversionResponse(
        bytes: Uint8List.fromList(data),
        serverFileName: _fileName(response.headers.value('content-disposition')),
        jobId: response.headers.value('x-conversion-id'),
      );
    } on DioException catch (error) {
      throw _mapDioError(error);
    }
  }

  @override
  Future<void> dispose() async => _dio.close(force: true);

  OfficeConversionException _mapDioError(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return const OfficeConversionException(
          OfficeErrorCode.timeout,
          'The conversion service took too long to respond. Try again.',
          retryable: true,
        );
      case DioExceptionType.connectionError:
      case DioExceptionType.badCertificate:
        return const OfficeConversionException(
          OfficeErrorCode.network,
          'Cannot reach the conversion service. Check your connection.',
          retryable: true,
        );
      case DioExceptionType.cancel:
        return const OfficeConversionException(
          OfficeErrorCode.cancelled,
          'Conversion cancelled.',
        );
      case DioExceptionType.badResponse:
        return _mapStatus(error);
      case DioExceptionType.unknown:
      case DioExceptionType.transformTimeout:
        return OfficeConversionException(
          OfficeErrorCode.unknown,
          'Conversion failed: ${error.message ?? 'unexpected error'}.',
          retryable: true,
        );
    }
  }

  OfficeConversionException _mapStatus(DioException error) {
    final status = error.response?.statusCode ?? 0;
    final body = _decodeErrorBody(error.response?.data);

    if (status == 413) {
      return OfficeConversionException(
        OfficeErrorCode.fileTooLarge,
        body?.message ?? 'The file is too large for the server.',
      );
    }
    if (status == 415 || status == 422) {
      return OfficeConversionException(
        OfficeErrorCode.unsupportedFormat,
        body?.message ?? 'This file cannot be converted to the selected format.',
      );
    }
    if (status == 401 || status == 403) {
      return const OfficeConversionException(
        OfficeErrorCode.unavailable,
        'The conversion service rejected the request. Check the API key.',
      );
    }
    if (status == 429) {
      return const OfficeConversionException(
        OfficeErrorCode.server,
        'Too many conversions right now. Wait a moment and retry.',
        retryable: true,
      );
    }
    if (status >= 500) {
      return OfficeConversionException(
        OfficeErrorCode.server,
        body?.message ?? 'The conversion service failed. Try again later.',
        retryable: true,
      );
    }
    return OfficeConversionException(
      OfficeErrorCode.server,
      body?.message ?? 'Conversion failed (HTTP $status).',
    );
  }

  OfficeApiErrorBody? _decodeErrorBody(Object? data) {
    if (data == null) return null;
    try {
      final text = data is List<int> ? utf8.decode(data) : data.toString();
      final json = jsonDecode(text);
      if (json is Map<String, dynamic>) {
        final error = json['error'];
        if (error is Map<String, dynamic>) {
          return OfficeApiErrorBody(
            code: error['code']?.toString() ?? 'unknown',
            message: error['message']?.toString() ?? 'Conversion failed.',
          );
        }
        if (json['message'] is String) {
          return OfficeApiErrorBody(
            code: 'unknown',
            message: json['message'] as String,
          );
        }
      }
    } catch (_) {
      // Non-JSON error body: fall back to the generic status message.
    }
    return null;
  }

  String? _fileName(String? disposition) {
    if (disposition == null) return null;
    final match = RegExp(r'filename\*?=(?:UTF-8\x27\x27)?"?([^";]+)"?')
        .firstMatch(disposition);
    return match?.group(1);
  }

  String _inputMime(String fileName) => switch (p.extension(fileName).toLowerCase()) {
    '.pdf' => 'pdf',
    '.docx' =>
      'vnd.openxmlformats-officedocument.wordprocessingml.document',
    '.xlsx' => 'vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    '.doc' => 'msword',
    '.xls' => 'vnd.ms-excel',
    _ => 'octet-stream',
  };
}
