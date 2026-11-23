import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models/scanned_file.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/status_views.dart';
import 'file_preview_screen.dart';
import 'files_controller.dart';

/// Local file hub: everything the app exported, searchable and manageable.
class FilesScreen extends StatefulWidget {
  const FilesScreen({super.key, required this.onStartScan});

  final VoidCallback onStartScan;

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _updateQuery(FilesController controller, String value) {
    _search.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    controller.setQuery(value);
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<FilesController>();
    final files = controller.files;
    final onStartScan = widget.onStartScan;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Files'),
        actions: [
          if (controller.totalCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(
                  '${controller.totalCount}',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
        ],
        bottom: controller.isBusy
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: Column(
        children: [
          if (controller.totalCount > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: TextField(
                controller: _search,
                onChanged: controller.setQuery,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Search files',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: controller.query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear',
                          icon: const Icon(Icons.close),
                          onPressed: () => _updateQuery(controller, ''),
                        ),
                ),
              ),
            ),
          if (controller.error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: ErrorBanner(
                message: controller.error!,
                onRetry: controller.clearError,
              ),
            ),
          Expanded(
            child: controller.totalCount == 0
                ? EmptyState(
                    icon: Icons.folder_open_outlined,
                    title: 'No files yet',
                    message:
                        'Scanned pages and converted files are saved here, '
                        'on this device only.',
                    action: FilledButton.icon(
                      onPressed: onStartScan,
                      icon: const Icon(Icons.document_scanner_outlined),
                      label: const Text('Start a scan'),
                    ),
                  )
                : files.isEmpty
                ? EmptyState(
                    icon: Icons.search_off,
                    title: 'No matches',
                    message: 'Nothing matches "${controller.query}".',
                    action: TextButton(
                      onPressed: () => _updateQuery(controller, ''),
                      child: const Text('Clear search'),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                    itemCount: files.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) => _FileTile(
                      file: files[index],
                      controller: controller,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _FileTile extends StatelessWidget {
  const _FileTile({required this.file, required this.controller});

  final ScannedFile file;
  final FilesController controller;

  Future<void> _onAction(BuildContext context, String action) async {
    switch (action) {
      case 'open':
        await controller.open(file);
      case 'share':
        await controller.share(file);
      case 'rename':
        await _rename(context);
      case 'delete':
        await _delete(context);
    }
  }

  Future<void> _rename(BuildContext context) async {
    final input = TextEditingController(text: file.name);
    input.selection = TextSelection(
      baseOffset: 0,
      extentOffset: Formatters.baseName(file.name).length,
    );
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename file'),
        content: TextField(
          controller: input,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'File name'),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(input.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    input.dispose();
    if (name != null && name.trim().isNotEmpty) {
      await controller.rename(file, name);
    }
  }

  Future<void> _delete(BuildContext context) async {
    final confirmed = await confirmDialog(
      context,
      title: 'Delete file?',
      message: '"${file.name}" will be removed from this device. This cannot '
          'be undone.',
    );
    if (confirmed) await controller.delete(file);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pages = file.pageCount;
    final subtitle = [
      file.kind.label,
      if (pages != null && pages > 1) '$pages pages',
      Formatters.bytes(file.sizeBytes),
      Formatters.dateTime(file.createdAt),
    ].join(' • ');

    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => FilePreviewScreen(file: file),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 52,
                  height: 64,
                  child: _Thumb(file: file),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'File actions',
                onSelected: (action) => _onAction(context, action),
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'open', child: Text('Open with…')),
                  PopupMenuItem(value: 'share', child: Text('Share')),
                  PopupMenuItem(value: 'rename', child: Text('Rename')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.file});

  final ScannedFile file;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (file.kind == FileKind.image) {
      return Image.file(
        File(file.path),
        fit: BoxFit.cover,
        cacheWidth: 160,
        errorBuilder: (context, error, stackTrace) =>
            _IconBox(icon: Icons.broken_image_outlined, color: scheme.errorContainer, iconColor: scheme.onErrorContainer),
      );
    }
    final (icon, color) = switch (file.kind) {
      FileKind.pdf => (Icons.picture_as_pdf_outlined, scheme.errorContainer),
      FileKind.document => (Icons.description_outlined, scheme.secondaryContainer),
      FileKind.spreadsheet => (Icons.table_chart_outlined, scheme.tertiaryContainer),
      _ => (Icons.insert_drive_file_outlined, scheme.surfaceContainerHighest),
    };
    return _IconBox(icon: icon, color: color);
  }
}

class _IconBox extends StatelessWidget {
  const _IconBox({required this.icon, required this.color, this.iconColor});

  final IconData icon;
  final Color color;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: color,
      child: Center(
        child: Icon(icon, color: iconColor ?? Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }
}
