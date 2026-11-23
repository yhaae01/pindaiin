import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

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

/// Owns one scan batch: the ordered pages plus their non-destructive edits.
///
/// A session folder under the cache is used for the page copies, so deleting or
/// cancelling a scan never touches the user's original photos.
class ScanController extends ChangeNotifier {
  ScanController({required AppServices services}) : _services = services;

  final AppServices _services;
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
    return _sessionDir ??= await _services.createSessionDirectory();
  }

  Future<void> addFromCamera() async {
    try {
      _setBusy('Opening camera…');
      final paths = await _services.fileAccess.capturePhoto();
      await addImages(paths);
    } catch (error) {
      _error = _describe(error);
    } finally {
      _clearBusy();
    }
  }

  Future<void> addFromGallery() async {
    try {
      _setBusy('Opening gallery…');
      final paths = await _services.fileAccess.pickFromGallery();
      await addImages(paths);
    } catch (error) {
      _error = _describe(error);
    } finally {
      _clearBusy();
    }
  }

  /// Copies [sourcePaths] into the session and appends them as pages.
  Future<void> addImages(List<String> sourcePaths) async {
    if (sourcePaths.isEmpty) return;
    try {
      _setBusy('Adding pages…');
      final dir = await _ensureSessionDir();
      for (final path in sourcePaths) {
        final copy = await _services.storage.copyIntoDirectory(path, dir);
        _pages.add(ScanPage(id: _uuid.v4(), imagePath: copy));
      }
      _currentIndex = _pages.length - 1;
      _error = null;
    } catch (error) {
      _error = _describe(error);
    } finally {
      _clearBusy();
    }
  }

  void select(int index) {
    if (index < 0 || index >= _pages.length) return;
    _currentIndex = index;
    _notify();
  }

  void reorder(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _pages.length) return;
    if (newIndex > oldIndex) newIndex -= 1;
    final page = _pages.removeAt(oldIndex);
    _pages.insert(newIndex.clamp(0, _pages.length), page);
    _currentIndex = newIndex.clamp(0, _pages.length - 1);
    _notify();
  }

  void rotateCurrent({bool clockwise = true}) {
    final index = currentIndex;
    if (_pages.isEmpty) return;
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
    _currentIndex = _currentIndex.clamp(0, _pages.length == 0 ? 0 : _pages.length - 1);
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
        final bytes = await _services.images.renderPage(
          _pages[index],
          quality: quality,
          asPng: format == ImageExportFormat.png,
        );
        final name =
            '${base}_p${(index + 1).toString().padLeft(2, '0')}.$extension';
        final path = await _services.storage.writeBytes(
          directory: _services.directories.scans,
          fileName: name,
          bytes: bytes,
        );
        files.add(
          await _services.registerFile(
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
        final bytes = await _services.images.renderPage(
          _pages[index],
          quality: quality,
        );
        rendered.add(bytes);
        _progress = 0.55 * (index + 1) / _pages.length;
        _notify();
      }

      final name = 'Scan_${Formatters.fileStamp(DateTime.now())}.pdf';
      final outputPath = await _services.storage.uniquePathIn(
        _services.directories.scans,
        name,
      );

      _busyLabel = 'Building PDF…';
      _notify();

      final path = await _services.pdf.bytesToPdf(
        jpegPages: rendered.map(Uint8List.fromList).toList(growable: false),
        outputPath: outputPath,
        onProgress: (progress) {
          _progress = 0.55 + 0.4 * progress;
          _notify();
        },
      );

      final file = await _services.registerFile(
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
      _services.storage.deleteDirectoryQuietly(dir.path);
    }
    super.dispose();
  }
}
