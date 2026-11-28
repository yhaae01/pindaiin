import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../core/document/document_corners.dart';
import '../../core/document/document_detector.dart';
import '../../core/models/conversion.dart';
import '../../core/models/scan_page.dart';
import '../../core/models/scanned_file.dart';
import '../../core/services/app_services.dart';
import '../../core/utils/formatters.dart';

enum ImageExportFormat {
  jpg('JPG'),
  png('PNG');

  const ImageExportFormat(this.label);
  final String label;
}

class ScanExportResult {
  const ScanExportResult({required this.files, required this.isPdf});

  final List<ScannedFile> files;
  final bool isPdf;
}

/// Outcome of adding one live-camera capture to the batch.
///
/// The page is added uncropped and the full-resolution photo is kept intact;
/// [detection] is the edge result the caller can seed the corner editor with.
/// The perspective warp runs only when the user confirms that editor.
class CapturedPageResult {
  const CapturedPageResult({required this.index, required this.detection});

  final int index;
  final DocumentDetection detection;
}

/// Owns one scan batch: the ordered pages plus their non-destructive edits.
///
/// A session folder under the cache is used for the page copies, so deleting or
/// cancelling a scan never touches the user's original photos.
class ScanController extends ChangeNotifier {
  ScanController({required this.services});

  final AppServices services;
  final Uuid _uuid = const Uuid();

  final List<ScanPage> _pages = [];
  Directory? _sessionDir;
  int _currentIndex = 0;
  bool _busy = false;
  String? _busyLabel;
  double? _progress;
  String? _error;
  bool _disposed = false;

  List<ScanPage> get pages => List.unmodifiable(_pages);
  int get pageCount => _pages.length;
  bool get isEmpty => _pages.isEmpty;
  int get currentIndex => _pages.isEmpty ? 0 : _currentIndex;
  bool get isBusy => _busy;
  String? get busyLabel => _busyLabel;
  double? get progress => _progress;
  String? get error => _error;

  ScanPage? get currentPage =>
      _pages.isEmpty ? null : _pages[_currentIndex.clamp(0, _pages.length - 1)];

  Future<Directory> _ensureSessionDir() async {
    return _sessionDir ??= await services.createSessionDirectory();
  }

  /// Captures one page. The photo is added untouched so the caller can show
  /// the edge adjustment screen before the page is straightened.
  ///
  /// Returns the index of the new page, or null when nothing was captured.
  Future<int?> addFromCamera() async {
    try {
      _setBusy('Opening camera…');
      final paths = await services.fileAccess.capturePhoto();
      if (paths.isEmpty) return null;
      final dir = await _ensureSessionDir();
      final index = await _appendPages(paths, dir);
      _error = null;
      return index;
    } catch (error) {
      _error = _describe(error);
      return null;
    } finally {
      _clearBusy();
    }
  }

  /// Adds one photo taken by the live scanner and detects its edges.
  ///
  /// The page is added uncropped on purpose: every capture goes through the
  /// corner editor, so the full-resolution photo is only perspective-warped
  /// after the user confirms it. The detection is returned so the editor can
  /// start from it instead of running the detector a second time.
  Future<CapturedPageResult?> addCapturedPhoto(String sourcePath) async {
    _setBusy('Processing page…');
    _error = null;
    try {
      final dir = await _ensureSessionDir();
      final copy = await services.storage.copyIntoDirectory(sourcePath, dir);
      _pages.add(ScanPage(id: _uuid.v4(), imagePath: copy));
      final index = _pages.length - 1;
      _currentIndex = index;
      _notify();

      DocumentDetection detection;
      try {
        detection = await services.documents.detectFile(copy);
      } catch (_) {
        detection = const DocumentDetection.unsure(
          note: 'Automatic edge detection failed. Adjust the corners manually.',
        );
      }

      return CapturedPageResult(index: index, detection: detection);
    } catch (error) {
      _error = _describe(error);
      return null;
    } finally {
      _clearBusy();
    }
  }

  Future<void> addFromGallery() async {
    try {
      _setBusy('Opening gallery…');
      final paths = await services.fileAccess.pickFromGallery();
      await addImages(paths);
    } catch (error) {
      _error = _describe(error);
    } finally {
      _clearBusy();
    }
  }

  /// Copies [sourcePaths] into the session and appends them as pages.
  ///
  /// When [autoStraighten] is true (bulk gallery imports) each page is run
  /// through edge detection and warped headlessly. Uncertain detections are
  /// left alone so the user can adjust them by hand in the batch editor.
  Future<void> addImages(
    List<String> sourcePaths, {
    bool autoStraighten = true,
  }) async {
    if (sourcePaths.isEmpty) return;
    try {
      _setBusy('Adding pages…');
      final dir = await _ensureSessionDir();
      final lastIndex = await _appendPages(sourcePaths, dir);
      _error = null;

      if (autoStraighten) {
        final firstIndex = lastIndex - sourcePaths.length + 1;
        for (var index = firstIndex; index <= lastIndex; index++) {
          _busyLabel = 'Detecting page edges…';
          _progress = (index - firstIndex) / sourcePaths.length;
          _notify();
          await _autoStraighten(index);
        }
      }
    } catch (error) {
      _error = _describe(error);
    } finally {
      _clearBusy();
    }
  }

  /// Copies the files into the session folder and returns the last page index.
  Future<int> _appendPages(List<String> sourcePaths, Directory dir) async {
    for (final path in sourcePaths) {
      final copy = await services.storage.copyIntoDirectory(path, dir);
      _pages.add(ScanPage(id: _uuid.v4(), imagePath: copy));
    }
    _currentIndex = _pages.length - 1;
    return _pages.length - 1;
  }

  /// Detects and warps a freshly imported page. Failures keep the original
  /// photo, which can still be adjusted manually.
  Future<void> _autoStraighten(int index) async {
    try {
      final detection = await detectPageEdges(index);
      if (!detection.isConfident || detection.corners.isFullFrame) return;
      await _warpPage(index, detection.corners);
    } catch (_) {
      // Best effort; the page stays as imported.
    }
  }

  /// Runs edge detection on the page source and returns corners already in the
  /// orientation the user sees (page rotation applied).
  Future<DocumentDetection> detectPageEdges(int index) async {
    final page = _pages[index];
    final detection = await services.documents.detectFile(
      page.editableSourcePath,
    );
    return detection.rotated(page.quarterTurns);
  }

  /// Warps the page to [corners] and replaces its working image.
  ///
  /// [corners] must be in the orientation of the page as displayed, i.e. after
  /// its current quarter turns. Rotation and crop are reset because they are
  /// baked into the new image, and the original photo is kept for later
  /// re-adjustment.
  Future<void> applyDocumentCorners(
    int index,
    DocumentCorners corners, {
    int? quarterTurns,
    ScanFilter? filter,
  }) async {
    if (index < 0 || index >= _pages.length) return;
    _setBusy('Straightening page…');
    try {
      await _warpPage(index, corners, quarterTurns: quarterTurns);
      if (filter != null) {
        _pages[index] = _pages[index].copyWith(filter: filter);
      }
      _error = null;
    } catch (error) {
      _error = _describe(error);
    } finally {
      _clearBusy();
    }
  }

  Future<void> _warpPage(
    int index,
    DocumentCorners corners, {
    int? quarterTurns,
  }) async {
    final page = _pages[index];
    final turns = (quarterTurns ?? page.quarterTurns) % 4;
    final source = page.editableSourcePath;

    // Nothing to straighten: keep the original bytes instead of re-encoding.
    final workingPath = corners.isFullFrame && corners.isValid && turns == 0
        ? source
        : await _writeWarpedPage(page, source, corners, turns);

    if (page.imagePath != source && page.imagePath != workingPath) {
      await services.storage.deleteQuietly(page.imagePath);
    }

    _pages[index] = page.copyWith(
      imagePath: workingPath,
      sourceImagePath: source,
      quarterTurns: 0,
      crop: const Rect.fromLTWH(0, 0, 1, 1),
    );
  }

  Future<String> _writeWarpedPage(
    ScanPage page,
    String source,
    DocumentCorners corners,
    int quarterTurns,
  ) async {
    final bytes = await services.documents.warpFile(
      source,
      corners: corners,
      quarterTurns: quarterTurns,
    );
    final dir = await _ensureSessionDir();
    return services.storage.writeBytes(
      directory: dir,
      fileName: 'page_${page.id}_straight.jpg',
      bytes: bytes,
    );
  }

  void select(int index) {
    if (index < 0 || index >= _pages.length) return;
    _currentIndex = index;
    _notify();
  }

  /// [newIndex] is already adjusted for the removed item (onReorderItem).
  void reorder(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _pages.length) return;
    final page = _pages.removeAt(oldIndex);
    final target = newIndex.clamp(0, _pages.length);
    _pages.insert(target, page);
    _currentIndex = target.clamp(0, _pages.length - 1);
    _notify();
  }

  void rotateCurrent({bool clockwise = true}) {
    if (_pages.isEmpty) return;
    rotatePage(currentIndex, clockwise: clockwise);
  }

  /// Rotates one page without changing the selection (used by the thumbnail
  /// strip's quick actions).
  void rotatePage(int index, {bool clockwise = true}) {
    if (index < 0 || index >= _pages.length) return;
    _pages[index] = clockwise
        ? _pages[index].rotatedClockwise()
        : _pages[index].rotatedCounterClockwise();
    _notify();
  }

  void setCrop(int index, Rect crop) {
    if (index < 0 || index >= _pages.length) return;
    _pages[index] = _pages[index].copyWith(crop: crop);
    _notify();
  }

  void resetCrop(int index) {
    setCrop(index, const Rect.fromLTWH(0, 0, 1, 1));
  }

  void setFilter(int index, ScanFilter filter) {
    if (index < 0 || index >= _pages.length) return;
    _pages[index] = _pages[index].copyWith(filter: filter);
    _notify();
  }

  void removePage(int index) {
    if (index < 0 || index >= _pages.length) return;
    _pages.removeAt(index);
    // Keep the same page selected when deleting an earlier one.
    if (index < _currentIndex) _currentIndex--;
    _currentIndex = _currentIndex.clamp(0, _pages.isEmpty ? 0 : _pages.length - 1);
    _notify();
  }

  void clearAll() {
    _pages.clear();
    _currentIndex = 0;
    _notify();
  }

  void clearError() {
    _error = null;
    _notify();
  }

  /// Renders every page with its edits and writes one file per page.
  Future<ScanExportResult> exportImages({
    required PdfQuality quality,
    required ImageExportFormat format,
  }) async {
    _setBusy('Rendering pages…', progress: 0);

    try {
      final base = 'Scan_${Formatters.fileStamp(DateTime.now())}';
      final extension = format == ImageExportFormat.png ? 'png' : 'jpg';
      final files = <ScannedFile>[];

      for (var index = 0; index < _pages.length; index++) {
        final bytes = await services.images.renderPage(
          _pages[index],
          quality: quality,
          asPng: format == ImageExportFormat.png,
        );
        final name =
            '${base}_p${(index + 1).toString().padLeft(2, '0')}.$extension';
        final path = await services.storage.writeBytes(
          directory: services.directories.scans,
          fileName: name,
          bytes: bytes,
        );
        files.add(
          await services.registerFile(
            path: path,
            origin: FileOrigin.scan,
            pageCount: 1,
          ),
        );
        _progress = 0.9 * (index + 1) / _pages.length;
        _notify();
      }

      return ScanExportResult(files: files, isPdf: false);
    } catch (error) {
      _error = _describe(error);
      rethrow;
    } finally {
      _clearBusy();
    }
  }

  /// Renders the batch and merges it into a single PDF.
  Future<ScanExportResult> exportPdf({required PdfQuality quality}) async {
    _setBusy('Rendering pages…', progress: 0);

    try {
      final rendered = <List<int>>[];
      for (var index = 0; index < _pages.length; index++) {
        final bytes = await services.images.renderPage(
          _pages[index],
          quality: quality,
        );
        rendered.add(bytes);
        _progress = 0.55 * (index + 1) / _pages.length;
        _notify();
      }

      final name = 'Scan_${Formatters.fileStamp(DateTime.now())}.pdf';
      final outputPath = await services.storage.uniquePathIn(
        services.directories.scans,
        name,
      );

      _busyLabel = 'Building PDF…';
      _notify();

      final path = await services.pdf.bytesToPdf(
        jpegPages: rendered.map(Uint8List.fromList).toList(growable: false),
        outputPath: outputPath,
        onProgress: (progress) {
          _progress = 0.55 + 0.4 * progress;
          _notify();
        },
      );

      final file = await services.registerFile(
        path: path,
        origin: FileOrigin.scan,
        pageCount: _pages.length,
      );
      return ScanExportResult(files: [file], isPdf: true);
    } catch (error) {
      _error = _describe(error);
      rethrow;
    } finally {
      _clearBusy();
    }
  }

  void _setBusy(String label, {double? progress}) {
    _busy = true;
    _busyLabel = label;
    _progress = progress;
    _notify();
  }

  void _clearBusy() {
    _busy = false;
    _busyLabel = null;
    _progress = null;
    _notify();
  }

  String _describe(Object error) {
    final message = error.toString();
    return message.replaceFirst(RegExp(r'^[A-Za-z]+Exception: '), '');
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    final dir = _sessionDir;
    if (dir != null) {
      // Best-effort cleanup of the temporary page copies.
      services.storage.deleteDirectoryQuietly(dir.path);
    }
    super.dispose();
  }
}
