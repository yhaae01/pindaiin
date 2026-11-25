import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models/conversion.dart';
import '../../core/models/pdf_edit.dart';
import '../../core/models/scanned_file.dart';
import '../../core/pdf/pdf_geometry.dart';
import '../../core/services/app_services.dart';
import '../../core/services/pdf_service.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/result_summary_card.dart';
import '../../core/widgets/status_views.dart';
import 'pdf_reader_screen.dart';

enum _EditorTool { none, text, highlight, draw }

/// PDF editor: page management, annotations, image/signature stamps and text
/// replacement. Every save writes a new PDF unless the user explicitly picks
/// overwrite.
class PdfEditorScreen extends StatefulWidget {
  const PdfEditorScreen({super.key, required this.file, this.password});

  final ScannedFile file;
  final String? password;

  @override
  State<PdfEditorScreen> createState() => _PdfEditorScreenState();
}

class _PdfEditorScreenState extends State<PdfEditorScreen> {
  static const _colors = <int>[
    0xFF111827,
    0xFFDC2626,
    0xFF2563EB,
    0xFF16A34A,
    0xFFF59E0B,
  ];

  PdfSession? _session;
  List<PdfPageRef> _pages = [];
  final List<PdfMark> _marks = [];
  final List<PdfTextReplacement> _textEdits = [];

  int _current = 0;
  int _colorIndex = 0;
  _EditorTool _tool = _EditorTool.none;
  Uint8List? _pageBytes;
  String? _renderError;
  PdfFailure? _failure;
  bool _loading = true;
  bool _busy = false;
  bool _dirty = false;
  double? _busyProgress;
  String _busyLabel = 'Working…';
  int _renderToken = 0;

  final List<Offset> _draftPoints = [];
  Rect? _draftHighlight;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void dispose() {
    _session?.close();
    super.dispose();
  }

  Future<void> _open() async {
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final services = context.read<AppServices>();
      final session = await services.pdfEditor.open(
        widget.file.path,
        password: widget.password,
      );
      if (!mounted) {
        await session.close();
        return;
      }
      setState(() {
        _session = session;
        _pages = [
          for (final page in session.pages)
            PdfPageRef(
              id: 'page-$page.page',
              sourcePage: page.page,
              width: page.width,
              height: page.height,
              initialQuarterTurns: page.quarterTurns,
            ),
        ];
        _loading = false;
        _current = 0;
      });
      _renderCurrent();
    } on PdfFailure catch (failure) {
      if (mounted) {
        setState(() {
          _failure = failure;
          _loading = false;
        });
      }
    }
  }

  PdfPageRef? get _page =>
      _current >= 0 && _current < _pages.length ? _pages[_current] : null;

  Future<void> _renderCurrent() async {
    final session = _session;
    final page = _page;
    if (session == null || page == null) return;
    final token = ++_renderToken;
    setState(() {
      _pageBytes = null;
      _renderError = null;
    });
    try {
      final bytes = await session.render(page.sourcePage, maxWidth: 1800);
      if (!mounted || token != _renderToken) return;
      setState(() => _pageBytes = bytes);
    } catch (_) {
      if (!mounted || token != _renderToken) return;
      setState(() => _renderError = 'This page could not be rendered.');
    }
  }

  void _selectPage(int index) {
    setState(() {
      _current = index;
      _tool = _EditorTool.none;
      _draftPoints.clear();
      _draftHighlight = null;
    });
    _renderCurrent();
  }

  void _rotatePage(int index) {
    if (index < 0 || index >= _pages.length) return;
    final page = _pages[index];
    final oldTotal = page.totalQuarterTurns;
    final updated = page.copyWith(
      rotationDelta: (page.rotationDelta + 1) % 4,
    );
    final newTotal = updated.totalQuarterTurns;
    for (var i = 0; i < _marks.length; i++) {
      final mark = _marks[i];
      if (mark.pageId != page.id) continue;
      _marks[i] = mark.copyWith(
        rect: PdfGeometry.rotateRect(mark.rect, oldTotal, newTotal),
        points: PdfGeometry.rotatePoints(
          mark.points,
          oldTotal,
          newTotal,
        ),
      );
    }
    setState(() {
      _pages[index] = updated;
      _dirty = true;
    });
  }

  void _deletePage(int index) {
    if (_pages.length <= 1) {
      showSnack(context, 'A PDF needs at least one page.');
      return;
    }
    final page = _pages[index];
    _pages.removeAt(index);
    _marks.removeWhere((mark) => mark.pageId == page.id);
    _textEdits.removeWhere((edit) => edit.pageId == page.id);
    setState(() {
      _current = _current.clamp(0, _pages.length - 1);
      _dirty = true;
    });
    _renderCurrent();
  }

  void _movePage(int from, int to) {
    if (from == to) return;
    final target = to.clamp(0, _pages.length - 1);
    final page = _pages.removeAt(from);
    _pages.insert(target, page);
    setState(() {
      _current = target;
      _dirty = true;
    });
    _renderCurrent();
  }

  List<PdfMark> get _pageMarks =>
      _marks.where((mark) => mark.pageId == _page?.id).toList(growable: false);

  void _addMark(PdfMark mark) {
    setState(() {
      _marks.add(mark);
      _dirty = true;
    });
  }

  Future<void> _handleTap(Offset local, Size size, PdfPageRef page) async {
    if (_tool != _EditorTool.text) return;
    final position = Offset(
      (local.dx / size.width).clamp(0.02, 0.95),
      (local.dy / size.height).clamp(0.02, 0.9),
    );
    final text = await showDialog<String>(
      context: context,
      builder: (context) => _TextInputDialog(),
    );
    if (text == null || text.trim().isEmpty || !mounted) return;
    _addMark(
      PdfMark(
        id: 'mark-${DateTime.now().microsecondsSinceEpoch}',
        pageId: page.id,
        kind: PdfMarkKind.text,
        rect: Rect.fromLTWH(
          position.dx.clamp(0, 0.45),
          position.dy,
          0.52,
          0.07,
        ),
        text: text.trim(),
        colorValue: _colors[_colorIndex],
        fontSize: 0.038,
      ),
    );
  }

  void _startDraw(Offset local, Size size) {
    if (_tool != _EditorTool.draw && _tool != _EditorTool.highlight) return;
    final point = Offset(local.dx / size.width, local.dy / size.height);
    setState(() {
      _draftPoints
        ..clear()
        ..add(point);
      _draftHighlight = _tool == _EditorTool.highlight
          ? Rect.fromPoints(point, point)
          : null;
    });
  }

  void _updateDraw(Offset local, Size size) {
    if (_draftPoints.isEmpty) return;
    final point = Offset(
      (local.dx / size.width).clamp(0, 1),
      (local.dy / size.height).clamp(0, 1),
    );
    setState(() {
      _draftPoints.add(point);
      if (_tool == _EditorTool.highlight) {
        _draftHighlight = Rect.fromPoints(_draftPoints.first, point);
      }
    });
  }

  void _finishDraw(PdfPageRef page) {
    if (_draftPoints.isEmpty) return;
    if (_tool == _EditorTool.highlight) {
      final rect = _draftHighlight;
      if (rect != null && rect.width > 0.005 && rect.height > 0.005) {
        _addMark(
          PdfMark(
            id: 'mark-${DateTime.now().microsecondsSinceEpoch}',
            pageId: page.id,
            kind: PdfMarkKind.highlight,
            rect: rect,
            colorValue: 0xFFFFEB3B,
            opacity: 0.35,
          ),
        );
      }
    } else {
      final rect = _boundsOf(_draftPoints).inflate(0.006);
      _addMark(
        PdfMark(
          id: 'mark-${DateTime.now().microsecondsSinceEpoch}',
          pageId: page.id,
          kind: PdfMarkKind.ink,
          rect: rect,
          points: List.of(_draftPoints),
          colorValue: _colors[_colorIndex],
          fontSize: 0.005,
        ),
      );
    }
    setState(() {
      _draftPoints.clear();
      _draftHighlight = null;
    });
  }

  Rect _boundsOf(List<Offset> points) {
    var left = points.first.dx;
    var right = points.first.dx;
    var top = points.first.dy;
    var bottom = points.first.dy;
    for (final point in points.skip(1)) {
      if (point.dx < left) left = point.dx;
      if (point.dx > right) right = point.dx;
      if (point.dy < top) top = point.dy;
      if (point.dy > bottom) bottom = point.dy;
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  Future<void> _addImageStamp() async {
    final page = _page;
    if (page == null) return;
    final paths = await context.read<AppServices>().fileAccess.pickFiles(
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp'],
      allowMultiple: false,
    );
    if (paths.isEmpty || !mounted) return;

    try {
      final bytes = await File(paths.first).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final imageWidth = frame.image.width;
      final imageHeight = frame.image.height;
      frame.image.dispose();
      if (!mounted) return;

      const width = 0.35;
      final aspect = page.displayWidth / page.displayHeight;
      final height =
          (width * aspect * imageHeight / imageWidth).clamp(0.05, 0.8);
      final rect = Rect.fromLTWH(
        (1 - width) / 2,
        (1 - height) / 2,
        width,
        height,
      );
      _addMark(
        PdfMark(
          id: 'mark-${DateTime.now().microsecondsSinceEpoch}',
          pageId: page.id,
          kind: PdfMarkKind.image,
          rect: rect,
          imagePath: paths.first,
        ),
      );
    } catch (_) {
      if (mounted) {
        showSnack(context, 'This image could not be read.');
      }
    }
  }

  void _clearMarkup() {
    setState(() {
      _marks.clear();
      _textEdits.clear();
      _dirty = true;
    });
  }

  Future<String> _writeTemp() async {
    final services = context.read<AppServices>();
    final dir = services.directories.temp;
    final path = await services.storage.uniquePathIn(
      dir,
      '${Formatters.baseName(widget.file.name)}_edit_'
      '${DateTime.now().microsecondsSinceEpoch}.pdf',
    );
    await services.pdfEditor.saveEdits(
      sourcePath: widget.file.path,
      outputPath: path,
      pages: _pages,
      marks: _marks,
      textEdits: _textEdits,
      password: widget.password,
    );
    return path;
  }

  Future<void> _saveAsNew() async {
    final services = context.read<AppServices>();
    setState(() {
      _busy = true;
      _busyProgress = null;
      _busyLabel = 'Saving a new PDF…';
    });
    try {
      final name =
          '${Formatters.baseName(widget.file.name)}_edited_'
          '${Formatters.fileStamp(DateTime.now())}.pdf';
      final path = await services.storage.uniquePathIn(
        services.directories.exports,
        name,
      );
      await services.pdfEditor.saveEdits(
        sourcePath: widget.file.path,
        outputPath: path,
        pages: _pages,
        marks: _marks,
        textEdits: _textEdits,
        password: widget.password,
        onProgress: (progress, label) {
          if (!mounted) return;
          setState(() {
            _busyProgress = progress;
            _busyLabel = label;
          });
        },
      );
      final saved = await services.registerFile(
        path: path,
        origin: FileOrigin.conversion,
        pageCount: _pages.length,
      );
      _dirty = false;
      if (!mounted) return;
      setState(() => _busy = false);
      await _showSaved(
        files: [saved],
        message: 'Saved as a new PDF. The original is unchanged.',
      );
    } on PdfFailure catch (failure) {
      if (!mounted) return;
      setState(() => _busy = false);
      showSnack(context, failure.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      showSnack(context, 'Could not save the PDF: $error');
    }
  }

  Future<void> _overwriteOriginal() async {
    final confirmed = await confirmDialog(
      context,
      title: 'Overwrite the original?',
      message:
          'The edited PDF replaces "${widget.file.name}" on this device. '
          'This cannot be undone.',
      confirmLabel: 'Overwrite',
    );
    if (!confirmed || !mounted) return;

    final services = context.read<AppServices>();
    setState(() {
      _busy = true;
      _busyProgress = null;
      _busyLabel = 'Overwriting the original…';
    });
    final original = File(widget.file.path);
    final backup = File('${widget.file.path}.pindaiin_backup');
    try {
      final temp = await services.storage.uniquePathIn(
        services.directories.temp,
        '${Formatters.baseName(widget.file.name)}_overwrite.pdf',
      );
      await services.pdfEditor.saveEdits(
        sourcePath: widget.file.path,
        outputPath: temp,
        pages: _pages,
        marks: _marks,
        textEdits: _textEdits,
        password: widget.password,
        onProgress: (progress, label) {
          if (!mounted) return;
          setState(() {
            _busyProgress = progress;
            _busyLabel = label;
          });
        },
      );

      if (await backup.exists()) await backup.delete();
      if (await original.exists()) await original.rename(backup.path);
      try {
        await File(temp).rename(original.path);
        if (await backup.exists()) await backup.delete();
      } catch (_) {
        if (await backup.exists()) await backup.rename(original.path);
        rethrow;
      }

      final updated = widget.file.copyWith(
        sizeBytes: await services.storage.sizeOf(original.path),
        pageCount: _pages.length,
      );
      await services.repository.save(updated);
      _dirty = false;
      if (!mounted) return;
      setState(() => _busy = false);
      showSnack(context, 'The original PDF was overwritten.');
      Navigator.of(context).pop(true);
    } on PdfFailure catch (failure) {
      if (!mounted) return;
      setState(() => _busy = false);
      showSnack(context, failure.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      showSnack(context, 'Could not overwrite the PDF: $error');
    }
  }

  Future<void> _merge() async {
    final other = await context.read<AppServices>().fileAccess.pickFiles(
      allowedExtensions: const ['pdf'],
      allowMultiple: false,
    );
    if (other.isEmpty || !mounted) return;
    if (other.first == widget.file.path) {
      showSnack(context, 'Choose a different PDF to merge.');
      return;
    }

    final services = context.read<AppServices>();
    setState(() {
      _busy = true;
      _busyProgress = null;
      _busyLabel = 'Preparing the merge…';
    });
    String? temp;
    try {
      temp = await _writeTemp();
      final path = await services.storage.uniquePathIn(
        services.directories.exports,
        '${Formatters.baseName(widget.file.name)}_merged_'
        '${Formatters.fileStamp(DateTime.now())}.pdf',
      );
      await services.pdfEditor.merge(
        inputPaths: [temp, other.first],
        outputPath: path,
      );
      final merged = await services.pdfEditor.open(path);
      final mergedPageCount = merged.pageCount;
      await merged.close();
      final saved = await services.registerFile(
        path: path,
        origin: FileOrigin.conversion,
        pageCount: mergedPageCount,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      await _showSaved(
        files: [saved],
        message: 'Merged with ${other.first.split(Platform.pathSeparator).last}.',
      );
    } on PdfFailure catch (failure) {
      if (!mounted) return;
      setState(() => _busy = false);
      showSnack(context, failure.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      showSnack(context, 'Could not merge the PDFs: $error');
    } finally {
      if (temp != null) await services.storage.deleteQuietly(temp);
    }
  }

  Future<void> _extractPages(List<int> selected) async {
    if (selected.isEmpty) return;
    final services = context.read<AppServices>();
    setState(() {
      _busy = true;
      _busyProgress = null;
      _busyLabel = 'Extracting pages…';
    });
    String? temp;
    try {
      temp = await _writeTemp();
      final path = await services.storage.uniquePathIn(
        services.directories.exports,
        '${Formatters.baseName(widget.file.name)}_pages_'
        '${Formatters.fileStamp(DateTime.now())}.pdf',
      );
      await services.pdfEditor.extractPages(
        sourcePath: temp,
        pages: selected,
        outputPath: path,
        password: widget.password,
      );
      final saved = await services.registerFile(
        path: path,
        origin: FileOrigin.conversion,
        pageCount: selected.length,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      await _showSaved(
        files: [saved],
        message: 'Extracted ${selected.length} page'
            '${selected.length == 1 ? '' : 's'} into a new PDF.',
      );
    } on PdfFailure catch (failure) {
      if (!mounted) return;
      setState(() => _busy = false);
      showSnack(context, failure.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      showSnack(context, 'Could not extract pages: $error');
    } finally {
      if (temp != null) await services.storage.deleteQuietly(temp);
    }
  }

  Future<void> _showSaved({
    required List<ScannedFile> files,
    required String message,
  }) async {
    if (!mounted) return;
    await showResultSummarySheet(
      context,
      title: files.length == 1 ? 'PDF saved' : 'PDFs saved',
      message: message,
      files: files,
      totalPageCount: files.fold<int>(
        0,
        (sum, file) => sum + (file.pageCount ?? 0),
      ),
      onPreview: (file) {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => PdfReaderScreen(file: file),
          ),
        );
      },
    );
    if (mounted) Navigator.of(context).pop(false);
  }

  Future<void> _openTextEditor() async {
    final session = _session;
    final page = _page;
    if (session == null || page == null) return;
    setState(() {
      _busy = true;
      _busyLabel = 'Checking the text layer…';
    });
    var hasText = true;
    try {
      hasText = await session.hasTextLayer(page.sourcePage);
    } catch (_) {
      hasText = true;
    }
    if (!mounted) return;
    setState(() => _busy = false);

    if (!hasText) {
      final convert = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Scanned PDF'),
          content: const Text(
            'This page has no editable text layer, so its text cannot be '
            'replaced directly. Convert the PDF to Word (DOCX) to edit it, or '
            'use the markup tools to place new text on top.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Convert to DOCX'),
            ),
          ],
        ),
      );
      if (convert == true) await _convertToDocx();
      return;
    }

    final replacement = await showDialog<PdfTextReplacement>(
      context: context,
      builder: (context) => _TextReplaceDialog(
        session: session,
        pages: _pages,
        onConvert: () {
          Navigator.of(context).pop();
          _convertToDocx();
        },
      ),
    );
    if (replacement == null || !mounted) return;
    setState(() {
      _textEdits.add(replacement);
      _dirty = true;
    });
    showSnack(
      context,
      'Text replacement queued. It is applied when you save the PDF.',
    );
  }

  Future<void> _convertToDocx() async {
    final services = context.read<AppServices>();
    if (!services.converter.isOfficeAvailable) {
      showSnack(context, services.converter.officeNote);
      return;
    }
    setState(() {
      _busy = true;
      _busyProgress = null;
      _busyLabel = 'Converting to Word…';
    });
    try {
      final result = await services.converter.convert(
        mode: ConversionMode.pdfToWord,
        inputPaths: [widget.file.path],
        quality: PdfQuality.balanced,
        outputDir: services.directories.exports,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() {
            _busyProgress = progress.fraction;
            _busyLabel = progress.label ?? 'Converting to Word…';
          });
        },
      );
      final saved = <ScannedFile>[];
      for (final artifact in result.artifacts) {
        saved.add(
          await services.registerFile(
            path: artifact.path,
            origin: FileOrigin.conversion,
            pageCount: artifact.pageCount,
          ),
        );
      }
      if (!mounted) return;
      setState(() => _busy = false);
      if (saved.isEmpty) {
        showSnack(context, 'The conversion produced no file.');
        return;
      }
      await showResultSummarySheet(
        context,
        title: 'Editable document created',
        message:
            'Text editing is now available in Word. The original PDF was not '
            'changed.',
        files: saved,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      showSnack(context, 'Conversion failed: $error');
    }
  }

  void _showPageManager() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          void refresh() {
            setSheetState(() {});
            setState(() {});
          }

          return SafeArea(
            child: SizedBox(
              height: MediaQuery.of(context).size.height * 0.7,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Pages (${_pages.length})',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () async {
                            final selected = await showDialog<List<int>>(
                              context: context,
                              builder: (_) =>
                                  _ExtractPagesDialog(count: _pages.length),
                            );
                            if (selected == null ||
                                !mounted ||
                                !sheetContext.mounted) {
                              return;
                            }
                            Navigator.of(sheetContext).pop();
                            await _extractPages(selected);
                          },
                          icon: const Icon(Icons.call_split),
                          label: const Text('Extract'),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ReorderableListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      buildDefaultDragHandles: true,
                      itemCount: _pages.length,
                      onReorderItem: (oldIndex, newIndex) {
                        _movePage(oldIndex, newIndex);
                        refresh();
                      },
                      itemBuilder: (context, index) {
                        final page = _pages[index];
                        final marks = _marks
                            .where((mark) => mark.pageId == page.id)
                            .length;
                        return Card(
                          key: ValueKey(page.id),
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          child: ListTile(
                            selected: index == _current,
                            onTap: () {
                              Navigator.of(sheetContext).pop();
                              _selectPage(index);
                            },
                            leading: CircleAvatar(
                              child: Text('${index + 1}'),
                            ),
                            title: Text(
                              '${page.displayWidth.round()} × '
                              '${page.displayHeight.round()} pt',
                            ),
                            subtitle: Text(
                              [
                                if (page.rotationDelta != 0)
                                  'Rotated ${page.rotationDelta * 90}°',
                                if (marks > 0) '$marks mark${marks == 1 ? '' : 's'}',
                              ].join(' • '),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: 'Rotate page',
                                  onPressed: () {
                                    _rotatePage(index);
                                    refresh();
                                  },
                                  icon: const Icon(Icons.rotate_right),
                                ),
                                IconButton(
                                  tooltip: 'Delete page',
                                  onPressed: _pages.length <= 1
                                      ? null
                                      : () {
                                          final wasCurrent = index == _current;
                                          _deletePage(index);
                                          if (wasCurrent) _renderCurrent();
                                          refresh();
                                        },
                                  icon: const Icon(Icons.delete_outline),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      'Drag to reorder. Rotation and deletions are applied '
                      'when you save.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final page = _page;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.file.name,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'Pages',
            onPressed: session == null ? null : _showPageManager,
            icon: const Icon(Icons.auto_awesome_motion_outlined),
          ),
          IconButton(
            tooltip: 'Edit text',
            onPressed: session == null || _busy ? null : _openTextEditor,
            icon: const Icon(Icons.text_fields),
          ),
          PopupMenuButton<String>(
            enabled: session != null && !_busy,
            tooltip: 'More edit actions',
            onSelected: (action) {
              switch (action) {
                case 'merge':
                  _merge();
                case 'overwrite':
                  _overwriteOriginal();
                case 'clear':
                  _clearMarkup();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'merge', child: Text('Merge with PDF…')),
              PopupMenuItem(
                value: 'overwrite',
                child: Text('Overwrite original…'),
              ),
              PopupMenuItem(value: 'clear', child: Text('Clear all markup')),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8, left: 4),
            child: FilledButton.icon(
              onPressed: session == null || _busy || page == null
                  ? null
                  : _saveAsNew,
              icon: const Icon(Icons.save_outlined),
              label: const Text('Save'),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (_failure != null || session == null || page == null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: ErrorBanner(
                  message:
                      _failure?.message ?? 'The PDF could not be opened.',
                  onRetry: _open,
                ),
              ),
            )
          else
            Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Row(
                    children: [
                      Text(
                        'Page ${_current + 1} of ${_pages.length}',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      const Spacer(),
                      if (_dirty)
                        Text(
                          'Unsaved changes',
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.primary,
                              ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Center(
                      child: _renderError != null
                          ? ErrorBanner(
                              message: _renderError!,
                              onRetry: _renderCurrent,
                            )
                          : _buildPage(page),
                    ),
                  ),
                ),
                _buildToolbar(page),
              ],
            ),
          if (_busy)
            BusyOverlay(message: _busyLabel, progress: _busyProgress),
        ],
      ),
    );
  }

  Widget _buildPage(PdfPageRef page) {
    final bytes = _pageBytes;
    if (bytes == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return AspectRatio(
      aspectRatio: page.displayWidth / page.displayHeight,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          final imageMarks = _pageMarks
              .where((mark) => mark.kind == PdfMarkKind.image)
              .toList(growable: false);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) =>
                _handleTap(details.localPosition, size, page),
            onPanStart: (details) =>
                _startDraw(details.localPosition, size),
            onPanUpdate: (details) =>
                _updateDraw(details.localPosition, size),
            onPanEnd: (_) => _finishDraw(page),
            child: Stack(
              fit: StackFit.expand,
              children: [
                RotatedBox(
                  quarterTurns: page.rotationDelta,
                  child: Image.memory(
                    bytes,
                    fit: BoxFit.fill,
                    gaplessPlayback: true,
                  ),
                ),
                CustomPaint(
                  painter: _MarkPainter(
                    marks: _pageMarks,
                    size: size,
                    draftPoints: _draftPoints,
                    draftHighlight: _draftHighlight,
                    draftColor: Color(_colors[_colorIndex]),
                  ),
                ),
                for (final mark in imageMarks)
                  Positioned.fromRect(
                    rect: Rect.fromLTWH(
                      mark.rect.left * size.width,
                      mark.rect.top * size.height,
                      mark.rect.width * size.width,
                      mark.rect.height * size.height,
                    ),
                    child: Opacity(
                      opacity: mark.opacity,
                      child: Image.file(
                        File(mark.imagePath!),
                        fit: BoxFit.fill,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildToolbar(PdfPageRef page) {
    final selected = _tool;
    return SafeArea(
      top: false,
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                _ToolButton(
                  icon: Icons.text_fields,
                  label: 'Text',
                  selected: selected == _EditorTool.text,
                  onTap: () => setState(
                    () => _tool = selected == _EditorTool.text
                        ? _EditorTool.none
                        : _EditorTool.text,
                  ),
                ),
                _ToolButton(
                  icon: Icons.highlight,
                  label: 'Highlight',
                  selected: selected == _EditorTool.highlight,
                  onTap: () => setState(
                    () => _tool = selected == _EditorTool.highlight
                        ? _EditorTool.none
                        : _EditorTool.highlight,
                  ),
                ),
                _ToolButton(
                  icon: Icons.draw_outlined,
                  label: 'Draw',
                  selected: selected == _EditorTool.draw,
                  onTap: () => setState(
                    () => _tool = selected == _EditorTool.draw
                        ? _EditorTool.none
                        : _EditorTool.draw,
                  ),
                ),
                _ToolButton(
                  icon: Icons.approval_outlined,
                  label: 'Stamp',
                  selected: false,
                  onTap: _addImageStamp,
                ),
                const SizedBox(width: 4),
                PopupMenuButton<int>(
                  tooltip: 'Ink color',
                  onSelected: (index) =>
                      setState(() => _colorIndex = index),
                  itemBuilder: (context) => [
                    for (var index = 0; index < _colors.length; index++)
                      PopupMenuItem(
                        value: index,
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 10,
                              backgroundColor: Color(_colors[index]),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              index == _colorIndex ? 'Selected' : 'Use color',
                            ),
                          ],
                        ),
                      ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: CircleAvatar(
                      radius: 12,
                      backgroundColor: Color(_colors[_colorIndex]),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Remove last mark',
                  onPressed: _marks.isEmpty
                      ? null
                      : () => setState(() {
                          _marks.removeLast();
                          _dirty = true;
                        }),
                  icon: const Icon(Icons.undo),
                ),
                if (_textEdits.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Chip(
                      avatar: const Icon(Icons.text_fields, size: 16),
                      label: Text('${_textEdits.length} text edits'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: TextButton.icon(
        onPressed: onTap,
        style: TextButton.styleFrom(
          backgroundColor: selected
              ? Theme.of(context).colorScheme.primaryContainer
              : null,
        ),
        icon: Icon(icon, size: 19),
        label: Text(label),
      ),
    );
  }
}

class _MarkPainter extends CustomPainter {
  const _MarkPainter({
    required this.marks,
    required this.size,
    required this.draftPoints,
    required this.draftHighlight,
    required this.draftColor,
  });

  final List<PdfMark> marks;
  final Size size;
  final List<Offset> draftPoints;
  final Rect? draftHighlight;
  final Color draftColor;

  @override
  void paint(Canvas canvas, Size canvasSize) {
    canvas.clipRect(Offset.zero & canvasSize);
    for (final mark in marks) {
      final rect = Rect.fromLTWH(
        mark.rect.left * canvasSize.width,
        mark.rect.top * canvasSize.height,
        mark.rect.width * canvasSize.width,
        mark.rect.height * canvasSize.height,
      );
      switch (mark.kind) {
        case PdfMarkKind.highlight:
          canvas.drawRect(
            rect,
            Paint()
              ..color = Color(mark.colorValue).withValues(alpha: mark.opacity),
          );
        case PdfMarkKind.ink:
          if (mark.points.length < 2) continue;
          final path = Path();
          final first = mark.points.first;
          path.moveTo(first.dx * canvasSize.width, first.dy * canvasSize.height);
          for (final point in mark.points.skip(1)) {
            path.lineTo(
              point.dx * canvasSize.width,
              point.dy * canvasSize.height,
            );
          }
          canvas.drawPath(
            path,
            Paint()
              ..color = Color(mark.colorValue).withValues(alpha: mark.opacity)
              ..style = PaintingStyle.stroke
              ..strokeWidth = (mark.fontSize * canvasSize.height).clamp(1, 14)
              ..strokeCap = StrokeCap.round
              ..strokeJoin = StrokeJoin.round,
          );
        case PdfMarkKind.text:
          final text = mark.text;
          if (text == null || text.isEmpty) continue;
          final painter = TextPainter(
            text: TextSpan(
              text: text,
              style: TextStyle(
                color: Color(mark.colorValue),
                fontSize: (mark.fontSize * canvasSize.height).clamp(8, 72),
                height: 1.1,
              ),
            ),
            textDirection: TextDirection.ltr,
            maxLines: 2,
            ellipsis: '…',
          )..layout(maxWidth: rect.width);
          painter.paint(canvas, rect.topLeft);
        case PdfMarkKind.image:
          break;
      }
    }

    if (draftHighlight != null) {
      canvas.drawRect(
        Rect.fromLTWH(
          draftHighlight!.left * canvasSize.width,
          draftHighlight!.top * canvasSize.height,
          draftHighlight!.width * canvasSize.width,
          draftHighlight!.height * canvasSize.height,
        ),
        Paint()..color = draftColor.withValues(alpha: 0.3),
      );
    }
    if (draftPoints.length > 1) {
      final path = Path();
      path.moveTo(
        draftPoints.first.dx * canvasSize.width,
        draftPoints.first.dy * canvasSize.height,
      );
      for (final point in draftPoints.skip(1)) {
        path.lineTo(
          point.dx * canvasSize.width,
          point.dy * canvasSize.height,
        );
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = draftColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MarkPainter oldDelegate) => true;
}

class _TextInputDialog extends StatefulWidget {
  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add text'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLines: 1,
        decoration: const InputDecoration(labelText: 'Text'),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Add'),
        ),
      ],
    );
  }
}

class _ExtractPagesDialog extends StatefulWidget {
  const _ExtractPagesDialog({required this.count});

  final int count;

  @override
  State<_ExtractPagesDialog> createState() => _ExtractPagesDialogState();
}

class _ExtractPagesDialogState extends State<_ExtractPagesDialog> {
  final Set<int> _selected = {};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Extract pages'),
      content: SizedBox(
        width: double.maxFinite,
        height: 320,
        child: ListView.builder(
          itemCount: widget.count,
          itemBuilder: (context, index) => CheckboxListTile(
            value: _selected.contains(index),
            title: Text('Page ${index + 1}'),
            onChanged: (checked) => setState(() {
              if (checked == true) {
                _selected.add(index);
              } else {
                _selected.remove(index);
              }
            }),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.of(context).pop(
                  (_selected.toList()..sort()),
                ),
          child: const Text('Extract'),
        ),
      ],
    );
  }
}

class _TextReplaceDialog extends StatefulWidget {
  const _TextReplaceDialog({
    required this.session,
    required this.pages,
    required this.onConvert,
  });

  final PdfSession session;
  final List<PdfPageRef> pages;
  final VoidCallback onConvert;

  @override
  State<_TextReplaceDialog> createState() => _TextReplaceDialogState();
}

class _TextReplaceDialogState extends State<_TextReplaceDialog> {
  final TextEditingController _query = TextEditingController();
  List<PdfTextHit> _hits = const [];
  bool _searching = false;
  bool _searched = false;
  String? _error;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _query.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final hits = await widget.session.searchText(query);
      final keptPages = widget.pages.map((page) => page.sourcePage).toSet();
      if (!mounted) return;
      setState(() {
        _hits = hits
            .where((hit) => keptPages.contains(hit.page))
            .take(80)
            .toList(growable: false);
        _searched = true;
        _searching = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'The text search failed.';
        _searched = true;
        _searching = false;
      });
    }
  }

  String _pageLabel(int sourcePage) {
    final index = widget.pages.indexWhere(
      (page) => page.sourcePage == sourcePage,
    );
    return index < 0 ? 'Page ?' : 'Page ${index + 1}';
  }

  Future<void> _replace(PdfTextHit hit) async {
    final replacement = await showDialog<String>(
      context: context,
      builder: (context) => _ReplacementDialog(original: hit.text),
    );
    if (replacement == null || replacement.trim().isEmpty || !mounted) return;
    final pageIndex = widget.pages.indexWhere(
      (page) => page.sourcePage == hit.page,
    );
    if (pageIndex < 0) return;
    Navigator.of(context).pop(
      PdfTextReplacement(
        pageId: widget.pages[pageIndex].id,
        sourcePage: hit.page,
        original: hit.text,
        replacement: replacement.trim(),
        left: hit.left,
        bottom: hit.bottom,
        right: hit.right,
        top: hit.top,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit PDF text'),
      content: SizedBox(
        width: double.maxFinite,
        height: 420,
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _query,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    decoration: const InputDecoration(
                      hintText: 'Find text',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _searching ? null : _search,
                  child: const Text('Find'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (_searching) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Expanded(
              child: _hits.isEmpty
                  ? Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: [
                            Icon(
                              _searched
                                  ? Icons.find_in_page_outlined
                                  : Icons.text_fields,
                              size: 40,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(height: 10),
                            Text(
                              _searched
                                  ? 'No matching text. This may be a scanned '
                                        'page with no text layer.'
                                  : 'Search for a word or phrase to replace it '
                                        'on the page.',
                              textAlign: TextAlign.center,
                            ),
                            if (_searched) ...[
                              const SizedBox(height: 12),
                              OutlinedButton.icon(
                                onPressed: widget.onConvert,
                                icon: const Icon(Icons.description_outlined),
                                label: const Text('Convert to DOCX'),
                              ),
                            ],
                          ],
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _hits.length,
                      itemBuilder: (context, index) {
                        final hit = _hits[index];
                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.text_snippet_outlined),
                          title: Text(
                            hit.text,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(_pageLabel(hit.page)),
                          onTap: () => _replace(hit),
                        );
                      },
                    ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: widget.onConvert,
                icon: const Icon(Icons.description_outlined),
                label: const Text('Scanned PDF? Convert to DOCX'),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _ReplacementDialog extends StatefulWidget {
  const _ReplacementDialog({required this.original});

  final String original;

  @override
  State<_ReplacementDialog> createState() => _ReplacementDialogState();
}

class _ReplacementDialogState extends State<_ReplacementDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.original,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Replace text'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Original: ${widget.original}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Replacement'),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Replace'),
        ),
      ],
    );
  }
}
