import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart' show ResultType;
import 'package:provider/provider.dart';

import '../models/scanned_file.dart';
import '../services/app_services.dart';
import '../services/file_access_service.dart';
import '../utils/formatters.dart';
import 'rename_dialog.dart';
import 'status_views.dart';

/// What the user chose at the bottom of a result summary sheet.
enum ResultSummaryAction { done, viewFiles }

/// Post-scan / post-conversion summary.
///
/// Shows file names, sizes and page counts and exposes the common follow-up
/// actions in one place: share (one or many files), open, rename and done. It is
/// used inline by the converter result and inside [showResultSummarySheet] for
/// scan exports, so both flows behave identically.
class ResultSummaryCard extends StatefulWidget {
  const ResultSummaryCard({
    super.key,
    required this.title,
    required this.files,
    this.message,
    this.totalPageCount,
    this.onViewFiles,
    this.onDone,
    this.onFileRenamed,
    this.onPreview,
  });

  final String title;
  final String? message;
  final List<ScannedFile> files;

  /// Total pages of the batch; falls back to the sum of per-file page counts.
  final int? totalPageCount;

  final VoidCallback? onViewFiles;
  final VoidCallback? onDone;
  final ValueChanged<ScannedFile>? onFileRenamed;

  /// In-app preview. When null, opening falls back to the system "Open with"
  /// intent.
  final ValueChanged<ScannedFile>? onPreview;

  @override
  State<ResultSummaryCard> createState() => _ResultSummaryCardState();
}

class _ResultSummaryCardState extends State<ResultSummaryCard> {
  late List<ScannedFile> _files = List.of(widget.files);
  bool _busy = false;

  @override
  void didUpdateWidget(covariant ResultSummaryCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Rename mutates name/path but keeps the id. Only resync when the result set
    // itself changed (a new export/conversion), so a local rename is not undone
    // by a repository rebuild.
    if (!_sameIds(widget.files, _files)) {
      _files = List.of(widget.files);
    }
  }

  bool get _single => _files.length == 1;

  int get _pageCount =>
      widget.totalPageCount ??
      _files.fold<int>(0, (sum, file) => sum + (file.pageCount ?? 1));

  String get _subject => _single ? _files.first.name : '${_files.length} files';

  Future<void> _share() async {
    if (_busy || _files.isEmpty) return;
    setState(() => _busy = true);
    try {
      final outcome = await context.read<AppServices>().fileAccess.shareFiles(
        _files.map((file) => file.path).toList(growable: false),
        subject: _subject,
      );
      if (!mounted) return;
      if (outcome.hasSkipped) {
        showSnack(
          context,
          'Shared ${outcome.sharedCount} file'
          '${outcome.sharedCount == 1 ? '' : 's'}. '
          '${outcome.skippedPaths.length} missing or unreadable file'
          '${outcome.skippedPaths.length == 1 ? ' was' : 's were'} skipped.',
        );
      }
    } on ShareException catch (error) {
      if (mounted) showSnack(context, error.message);
    } catch (error) {
      if (mounted) {
        showSnack(context, 'Could not share the file: ${_clean(error)}');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(ScannedFile file) async {
    if (_busy) return;
    final preview = widget.onPreview;
    if (preview != null) {
      preview(file);
      return;
    }
    try {
      final result = await context
          .read<AppServices>()
          .fileAccess
          .openExternally(file.path);
      if (!mounted) return;
      if (result.type != ResultType.done) {
        showSnack(
          context,
          result.message.isEmpty
              ? 'No app on this device can open ${file.name}.'
              : result.message,
        );
      }
    } catch (error) {
      if (mounted) {
        showSnack(context, 'Could not open the file: ${_clean(error)}');
      }
    }
  }

  Future<void> _rename() async {
    if (_busy || _files.isEmpty) return;
    final file = _files.first;
    final name = await showRenameFileDialog(context, currentName: file.name);
    if (name == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final updated = await context.read<AppServices>().renameFile(file, name);
      if (!mounted) return;
      setState(() => _files = [updated]);
      widget.onFileRenamed?.call(updated);
      showSnack(context, 'Renamed to ${updated.name}');
    } catch (error) {
      if (!mounted) return;
      final message = error.toString().contains('already exists')
          ? 'A file named "$name" already exists.'
          : 'Rename failed: ${_clean(error)}';
      showSnack(context, message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = scheme.onPrimaryContainer;
    final visible = _files.take(6).toList(growable: false);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.check_circle_outline, color: foreground),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (_busy)
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: foreground,
                  ),
                ),
            ],
          ),
          if (widget.message != null) ...[
            const SizedBox(height: 4),
            Text(
              widget.message!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: foreground.withValues(alpha: 0.8),
              ),
            ),
          ],
          if (_pageCount > 1) ...[
            const SizedBox(height: 6),
            Text(
              '$_pageCount pages',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: foreground.withValues(alpha: 0.8),
              ),
            ),
          ],
          const SizedBox(height: 10),
          ...visible.map(
            (file) => _SummaryFileRow(
              file: file,
              foreground: foreground,
              onOpen: _busy ? null : () => _open(file),
            ),
          ),
          if (_files.length > visible.length)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '+ ${_files.length - visible.length} more',
                style: TextStyle(color: foreground.withValues(alpha: 0.8)),
              ),
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _busy || _files.isEmpty ? null : _share,
                icon: const Icon(Icons.share_outlined),
                label: Text(
                  _single ? 'Share' : 'Share ${_files.length} files',
                ),
              ),
              if (_single)
                OutlinedButton.icon(
                  onPressed: _busy ? null : _rename,
                  icon: const Icon(Icons.drive_file_rename_outline),
                  label: const Text('Rename'),
                ),
              OutlinedButton.icon(
                onPressed: _busy || _files.isEmpty
                    ? null
                    : () => _open(_files.first),
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open'),
              ),
              if (widget.onViewFiles != null)
                TextButton.icon(
                  onPressed: _busy ? null : widget.onViewFiles,
                  icon: const Icon(Icons.folder_outlined),
                  label: const Text('View in Files'),
                ),
              if (widget.onDone != null)
                FilledButton.tonal(
                  onPressed: _busy ? null : widget.onDone,
                  child: const Text('Done'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  static bool _sameIds(List<ScannedFile> a, List<ScannedFile> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index].id != b[index].id) return false;
    }
    return true;
  }

  String _clean(Object error) =>
      error.toString().replaceFirst(RegExp(r'^[A-Za-z]+Exception: '), '');
}

class _SummaryFileRow extends StatelessWidget {
  const _SummaryFileRow({
    required this.file,
    required this.foreground,
    required this.onOpen,
  });

  final ScannedFile file;
  final Color foreground;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final pages = file.pageCount;
    final details = [
      file.kind.label,
      Formatters.bytes(file.sizeBytes),
      if (pages != null && pages > 1) '$pages pages',
    ].join(' • ');

    return Row(
      children: [
        Icon(_iconFor(file.kind), size: 18, color: foreground),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                file.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: foreground, fontSize: 13),
              ),
              Text(
                details,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: foreground.withValues(alpha: 0.7),
                  fontSize: 11.5,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Open with another app',
          onPressed: onOpen,
          visualDensity: VisualDensity.compact,
          icon: Icon(Icons.open_in_new, size: 18, color: foreground),
        ),
      ],
    );
  }

  static IconData _iconFor(FileKind kind) => switch (kind) {
    FileKind.pdf => Icons.picture_as_pdf_outlined,
    FileKind.image => Icons.image_outlined,
    FileKind.document => Icons.description_outlined,
    FileKind.spreadsheet => Icons.table_chart_outlined,
    FileKind.other => Icons.insert_drive_file_outlined,
  };
}

/// Shows the result summary as a modal sheet. Returns null when dismissed.
Future<ResultSummaryAction?> showResultSummarySheet(
  BuildContext context, {
  required String title,
  required List<ScannedFile> files,
  String? message,
  int? totalPageCount,
  ValueChanged<ScannedFile>? onPreview,
}) {
  return showModalBottomSheet<ResultSummaryAction>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: ResultSummaryCard(
          title: title,
          message: message,
          files: files,
          totalPageCount: totalPageCount,
          onPreview: onPreview,
          onDone: () => Navigator.of(sheetContext).pop(ResultSummaryAction.done),
          onViewFiles: () =>
              Navigator.of(sheetContext).pop(ResultSummaryAction.viewFiles),
        ),
      ),
    ),
  );
}
