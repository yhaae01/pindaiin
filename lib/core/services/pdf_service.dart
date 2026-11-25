import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:pdf_manipulator/io.dart';
import 'package:pdf_manipulator/pdf_manipulator.dart';

import '../models/pdf_edit.dart';
import '../pdf/pdf_geometry.dart';

/// What kind of problem stopped a PDF operation. The UI maps these to copy
/// rather than showing raw engine errors.
enum PdfFailureKind { passwordRequired, wrongPassword, corrupted, unsupported, io, unknown }

class PdfFailure implements Exception {
  const PdfFailure(this.message, {this.kind = PdfFailureKind.unknown});

  final String message;
  final PdfFailureKind kind;

  @override
  String toString() => 'PdfFailure: $message';
}

/// Simple page metrics exposed to the UI without leaking the engine package.
class PdfPageMetrics {
  const PdfPageMetrics({
    required this.page,
    required this.width,
    required this.height,
    required this.quarterTurns,
  });

  final int page;
  final double width;
  final double height;

  /// `/Rotate` already present in the file, as clockwise quarter turns.
  final int quarterTurns;
}

class PdfTextHit {
  const PdfTextHit({
    required this.page,
    required this.text,
    required this.left,
    required this.bottom,
    required this.right,
    required this.top,
  });

  final int page;
  final String text;
  final double left;
  final double bottom;
  final double right;
  final double top;
}

class PdfFileInfo {
  const PdfFileInfo({
    required this.path,
    required this.name,
    required this.sizeBytes,
    required this.modifiedOnDisk,
    required this.pageCount,
    required this.version,
    required this.isTagged,
    required this.isEncrypted,
    required this.requiresPassword,
    required this.metadata,
  });

  final String path;
  final String name;
  final int sizeBytes;
  final DateTime modifiedOnDisk;
  final int pageCount;
  final String version;
  final bool isTagged;
  final bool isEncrypted;
  final bool requiresPassword;
  final PdfMetadata metadata;
}

/// One open PDF. Rendering, search and classification reuse the parsed
/// document, so scrolling and editing do not re-open the file for every page.
class PdfSession {
  PdfSession._(this._pdf, this._document, this._pages);

  final Pdf _pdf;
  final PdfDocumentHandle _document;
  final List<PdfPageMetrics> _pages;

  int get pageCount => _document.pageCount;
  List<PdfPageMetrics> get pages => List.unmodifiable(_pages);
  bool get isEncrypted => _document.encryption != null;

  Future<Uint8List> render(
    int page, {
    int maxWidth = 1500,
  }) async {
    final bitmap = await _document.bitmap(
      page,
      size: PdfRenderSize.fit(maxWidth: maxWidth, maxHeight: maxWidth * 2),
      format: PdfRenderFormat.png,
    );
    return bitmap.bytes;
  }

  Future<String> text(int page) {
    return _document.text(pages: PdfPages.single(page));
  }

  Future<List<PdfSearchHit>> search(String query, {int? page}) {
    return _document.search(
      query,
      pages: page == null ? const PdfPages.all() : PdfPages.single(page),
    );
  }

  Future<List<PdfTextHit>> searchText(String query, {int? page}) async {
    final hits = await search(query, page: page);
    return hits
        .map(
          (hit) => PdfTextHit(
            page: hit.page,
            text: hit.text,
            left: hit.bounds.left,
            bottom: hit.bounds.bottom,
            right: hit.bounds.right,
            top: hit.bounds.top,
          ),
        )
        .toList(growable: false);
  }

  Future<PdfPageKind> classify(int page) async {
    final result = await _document.classifyPages(
      pages: PdfPages.single(page),
    );
    return result.single.kind;
  }

  /// Whether the page has useful selectable text. Image-only pages need OCR or
  /// a DOCX conversion before their text can be edited.
  Future<bool> hasTextLayer(int page) async {
    final kind = await classify(page);
    return kind == PdfPageKind.textLayer ||
        kind == PdfPageKind.imageText ||
        kind == PdfPageKind.mixed;
  }

  Future<void> close() async {
    await _document.dispose();
    await _pdf.dispose();
  }
}

/// All PDF reading and writing goes through this service: page rendering,
/// metadata, text lookup, page management, annotations and text replacement.
class PdfService {
  PdfService();

  Future<PdfSession> open(String path, {String? password}) async {
    final file = File(path);
    if (!await file.exists()) {
      throw const PdfFailure(
        'This PDF no longer exists on disk.',
        kind: PdfFailureKind.io,
      );
    }

    final pdf = Pdf();
    try {
      final document = await pdf.open(
        PdfFile(file, password: password),
      );
      final info = await document.pageInfo();
      final pages = info
          .map(
            (page) => PdfPageMetrics(
              page: page.page,
              width: page.width,
              height: page.height,
              quarterTurns: _quarterTurns(page.rotation),
            ),
          )
          .toList(growable: false);
      return PdfSession._(pdf, document, pages);
    } catch (error) {
      await pdf.dispose();
      throw _mapError(error);
    }
  }

  Future<PdfFileInfo> fileInfo(String path, PdfSession session) async {
    final file = File(path);
    final exists = await file.exists();
    final modified = exists
        ? await file.lastModified()
        : DateTime.fromMillisecondsSinceEpoch(0);
    final metadata = session._document.metadata;
    final encryption = session._document.encryption;
    return PdfFileInfo(
      path: path,
      name: p.basename(path),
      sizeBytes: exists ? await file.length() : 0,
      modifiedOnDisk: modified,
      pageCount: session.pageCount,
      version: session._document.version,
      isTagged: session._document.isTagged,
      isEncrypted: encryption != null,
      requiresPassword: encryption?.requiresPassword ?? false,
      metadata: metadata,
    );
  }

  /// Applies pending page order/rotation, text replacements and markup and
  /// writes a new PDF to [outputPath].
  ///
  /// The source is never modified. The caller writes to a temporary path and
  /// atomically replaces the original when the user explicitly chose
  /// overwrite.
  Future<void> saveEdits({
    required String sourcePath,
    required String outputPath,
    required List<PdfPageRef> pages,
    required List<PdfMark> marks,
    required List<PdfTextReplacement> textEdits,
    String? password,
    void Function(double progress, String label)? onProgress,
  }) async {
    if (pages.isEmpty) {
      throw const PdfFailure('A PDF needs at least one page.');
    }
    final output = File(outputPath);
    await output.parent.create(recursive: true);

    final marksByPage = <String, List<PdfMark>>{};
    for (final mark in marks) {
      marksByPage.putIfAbsent(mark.pageId, () => []).add(mark);
    }
    final keptPageIds = pages.map((page) => page.id).toSet();
    final pageBySource = {
      for (final page in pages) page.sourcePage: page,
    };
    final textsByPage = <int, List<PdfTextReplacement>>{};
    for (final edit in textEdits) {
      if (!keptPageIds.contains(edit.pageId)) continue;
      textsByPage.putIfAbsent(edit.sourcePage, () => []).add(edit);
    }

    final pdf = Pdf();
    final sink = await FileSink.open(output);
    try {
      onProgress?.call(0.1, 'Preparing document…');
      await pdf.rewrite(
        PdfFile(File(sourcePath), password: password),
        sink,
        (editor) async {
          // Text replacement: erase the original glyphs, then stamp the new
          // text at the same baseline box.
          var done = 0;
          final total = textsByPage.length + marksByPage.length;
          for (final entry in textsByPage.entries) {
            final edits = entry.value;
            await editor.redact(
              entry.key,
              edits
                  .map(
                    (edit) => PdfRect.fromEdges(
                      left: edit.left,
                      bottom: edit.bottom,
                      right: edit.right,
                      top: edit.top,
                    ),
                  )
                  .toList(growable: false),
              overlay: const PdfRedactionOverlay.none(),
            );
            for (final edit in edits) {
              await editor.addWatermark(
                edit.replacement,
                pages: PdfPages.single(entry.key),
                style: PdfWatermarkStyle(
                  fontSize: _replacementFontSize(edit),
                  opacity: 1,
                  // Compensate the page's /Rotate so the replacement reads
                  // upright instead of being baked sideways.
                  angleDegrees:
                      90.0 *
                      (pageBySource[edit.sourcePage]?.totalQuarterTurns ?? 0),
                  color: PdfColor.black,
                ),
                position: PdfWatermarkPosition.exact(
                  PdfRect.fromEdges(
                    left: edit.left,
                    bottom: edit.bottom,
                    right: edit.right,
                    top: edit.top,
                  ),
                ),
                // Foreground is required: a background watermark is hidden by
                // the page's opaque white content. The redaction removes the
                // original text and this stamp supplies the visible
                // replacement.
                layer: PdfWatermarkLayer.foreground,
              );
            }
            done++;
            onProgress?.call(
              0.15 + 0.55 * done / (total == 0 ? 1 : total),
              'Replacing text…',
            );
          }

          for (final page in pages) {
            final pageMarks = marksByPage[page.id];
            if (pageMarks == null || pageMarks.isEmpty) continue;
            for (final mark in pageMarks) {
              await _applyMark(editor, mark, page);
            }
            done++;
            onProgress?.call(
              0.15 + 0.55 * done / (total == 0 ? 1 : total),
              'Adding markup…',
            );
          }

          // Bake every stamp (including replacement text) into page content.
          // Some renderers do not paint annotation appearances; flattening
          // guarantees the saved output looks like the editor preview.
          onProgress?.call(0.72, 'Flattening annotations…');
          await editor.flattenAnnotations();

          onProgress?.call(0.78, 'Applying page order…');
          await editor.reorderPages(
            PdfPageOrder(pages.map((page) => page.sourcePage).toList()),
          );

          for (var index = 0; index < pages.length; index++) {
            await editor.setRotation(
              _rotationFor(pages[index].totalQuarterTurns),
              pages: PdfPages.single(index),
            );
          }
        },
        save: const PdfSave.full(mergeDuplicates: true),
      );
      await sink.close();
      onProgress?.call(1, 'Saved');
    } catch (error) {
      await sink.abort(error);
      await sink.close();
      if (await output.exists()) await output.delete();
      throw _mapError(error);
    } finally {
      await pdf.dispose();
    }
  }

  Future<void> merge({
    required List<String> inputPaths,
    required String outputPath,
    void Function(double progress)? onProgress,
  }) async {
    if (inputPaths.length < 2) {
      throw const PdfFailure('Choose at least two PDFs to merge.');
    }
    final output = File(outputPath);
    await output.parent.create(recursive: true);
    final pdf = Pdf();
    final sink = await FileSink.open(output);
    try {
      onProgress?.call(0.1);
      await pdf.merge(
        inputPaths.map((path) => PdfFile(File(path))).toList(),
        sink,
      );
      await sink.close();
      onProgress?.call(1);
    } catch (error) {
      await sink.abort(error);
      await sink.close();
      if (await output.exists()) await output.delete();
      throw _mapError(error);
    } finally {
      await pdf.dispose();
    }
  }

  Future<void> extractPages({
    required String sourcePath,
    required List<int> pages,
    required String outputPath,
    String? password,
    void Function(double progress)? onProgress,
  }) async {
    if (pages.isEmpty) {
      throw const PdfFailure('Select at least one page to extract.');
    }
    final output = File(outputPath);
    await output.parent.create(recursive: true);
    final pdf = Pdf();
    final sink = await FileSink.open(output);
    try {
      onProgress?.call(0.1);
      await pdf.rewrite(
        PdfFile(File(sourcePath), password: password),
        sink,
        (editor) async {
          await editor.keepPages(PdfPages.list(pages));
        },
      );
      await sink.close();
      onProgress?.call(1);
    } catch (error) {
      await sink.abort(error);
      await sink.close();
      if (await output.exists()) await output.delete();
      throw _mapError(error);
    } finally {
      await pdf.dispose();
    }
  }

  Future<void> _applyMark(
    PdfEditor editor,
    PdfMark mark,
    PdfPageRef page,
  ) async {
    final bounds = PdfGeometry.toPdfPoints(
      rect: mark.rect,
      quarterTurns: page.totalQuarterTurns,
      pageWidth: page.width,
      pageHeight: page.height,
    );
    final rect = PdfRect.fromEdges(
      left: bounds.left,
      bottom: bounds.bottom,
      right: bounds.right,
      top: bounds.top,
    );

    switch (mark.kind) {
      case PdfMarkKind.text:
        final text = mark.text?.trim();
        if (text == null || text.isEmpty) return;
        await editor.addWatermark(
          text,
          pages: PdfPages.single(page.sourcePage),
          style: PdfWatermarkStyle(
            fontSize: (mark.fontSize * page.height).clamp(6, 96),
            opacity: mark.opacity,
            angleDegrees: 90.0 * page.totalQuarterTurns,
            color: _pdfColor(mark.colorValue),
          ),
          position: PdfWatermarkPosition.exact(rect),
        );
      case PdfMarkKind.highlight:
        final bytes = _solidPng(
          mark.colorValue,
          (mark.opacity * 255).round(),
        );
        await editor.addImageStamp(
          MemorySource(bytes),
          bounds: rect,
          pages: PdfPages.single(page.sourcePage),
        );
      case PdfMarkKind.ink:
        final bytes = _inkPng(mark, page);
        if (bytes == null) return;
        await editor.addImageStamp(
          MemorySource(bytes),
          bounds: rect,
          pages: PdfPages.single(page.sourcePage),
        );
      case PdfMarkKind.image:
        final path = mark.imagePath;
        if (path == null) return;
        final file = File(path);
        if (!await file.exists()) return;
        await editor.addImageStamp(
          MemorySource(await file.readAsBytes()),
          bounds: rect,
          pages: PdfPages.single(page.sourcePage),
          opacity: mark.opacity,
        );
    }
  }

  Uint8List _solidPng(int colorValue, int alpha) {
    final image = img.Image(width: 8, height: 8, numChannels: 4);
    final color = _rgba(colorValue, alpha);
    img.fill(image, color: color);
    return Uint8List.fromList(img.encodePng(image));
  }

  Uint8List? _inkPng(PdfMark mark, PdfPageRef page) {
    if (mark.points.length < 2 || mark.rect.width <= 0 || mark.rect.height <= 0) {
      return null;
    }
    // Match the stamp bounds' aspect ratio so the drawing is not stretched.
    final displayAspect =
        (mark.rect.width * page.displayWidth) /
        (mark.rect.height * page.displayHeight);
    final pxWidth = (page.displayWidth * 1.5).clamp(200, 2000).round();
    final pxHeight = (pxWidth / displayAspect).clamp(80, 2600).round();
    final image = img.Image(width: pxWidth, height: pxHeight, numChannels: 4);
    img.fill(image, color: img.ColorRgba8(0, 0, 0, 0));
    final color = _rgba(mark.colorValue, (mark.opacity * 255).round());
    final rect = mark.rect;
    final stroke = (mark.fontSize * pxHeight).clamp(1.0, 40.0);

    Offset toPixel(Offset point) {
      final nx = (point.dx - rect.left) / rect.width;
      final ny = (point.dy - rect.top) / rect.height;
      return Offset(nx * pxWidth, ny * pxHeight);
    }

    var previous = toPixel(mark.points.first);
    for (var index = 1; index < mark.points.length; index++) {
      final current = toPixel(mark.points[index]);
      img.drawLine(
        image,
        x1: previous.dx.round(),
        y1: previous.dy.round(),
        x2: current.dx.round(),
        y2: current.dy.round(),
        color: color,
        thickness: stroke,
        antialias: true,
      );
      previous = current;
    }
    return Uint8List.fromList(img.encodePng(image));
  }

  img.ColorRgba8 _rgba(int colorValue, int alpha) {
    return img.ColorRgba8(
      (colorValue >> 16) & 0xFF,
      (colorValue >> 8) & 0xFF,
      colorValue & 0xFF,
      alpha.clamp(0, 255),
    );
  }

  PdfColor _pdfColor(int colorValue) {
    return PdfColor(
      ((colorValue >> 16) & 0xFF) / 255,
      ((colorValue >> 8) & 0xFF) / 255,
      (colorValue & 0xFF) / 255,
    );
  }

  double _replacementFontSize(PdfTextReplacement edit) {
    final height = edit.height <= 0 ? 10.0 : edit.height;
    return (height * 0.92).clamp(5, 72);
  }

  int _quarterTurns(PdfRotation rotation) => switch (rotation) {
    PdfRotation.r90 => 1,
    PdfRotation.r180 => 2,
    PdfRotation.r270 => 3,
    PdfRotation.r0 => 0,
  };

  PdfRotation _rotationFor(int quarterTurns) => switch (quarterTurns % 4) {
    1 => PdfRotation.r90,
    2 => PdfRotation.r180,
    3 => PdfRotation.r270,
    _ => PdfRotation.r0,
  };

  PdfFailure _mapError(Object error) {
    if (error is PdfFailure) return error;
    if (error is PdfPasswordRequired) {
      return const PdfFailure(
        'This PDF is password-protected. Enter the password to continue.',
        kind: PdfFailureKind.passwordRequired,
      );
    }
    if (error is PdfWrongPassword) {
      return const PdfFailure(
        'That password is not correct.',
        kind: PdfFailureKind.wrongPassword,
      );
    }
    if (error is PdfCorrupted) {
      return const PdfFailure(
        'This PDF appears to be corrupted or incomplete.',
        kind: PdfFailureKind.corrupted,
      );
    }
    if (error is PdfUnsupported) {
      return PdfFailure(
        'This PDF uses a feature the editor does not support: ${error.message}',
        kind: PdfFailureKind.unsupported,
      );
    }
    if (error is PdfIoFailed) {
      return PdfFailure(
        'The PDF could not be read from disk: ${error.message}',
        kind: PdfFailureKind.io,
      );
    }
    if (error is PdfError) {
      return PdfFailure(
        'The PDF operation failed: ${error.message}',
      );
    }
    return PdfFailure('The PDF operation failed: $error');
  }
}
