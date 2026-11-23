import 'office_conversion_models.dart';

/// Boundary between the app and an Office conversion engine.
///
/// The app ships two implementations:
///  - [MockOfficeConversionRepository] for demo/offline runs, and
///  - [RestOfficeConversionRepository] for a REST/self-hosted backend.
///
/// Swapping implementations never touches controllers or widgets.
abstract class OfficeConversionRepository {
  /// False for the mock, true for a network backend.
  bool get isRemote;

  /// Shown in the converter UI (e.g. host name or "Demo converter").
  String get backendLabel;

  /// Client-side guard; the server must enforce the same limit.
  int get maxUploadBytes;

  Future<OfficeConversionResponse> convert(
    OfficeConversionRequest request, {
    OfficeProgressCallback? onProgress,
  });

  Future<void> dispose() async {}
}
