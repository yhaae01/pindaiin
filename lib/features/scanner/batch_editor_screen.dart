import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/app_services.dart';
import '../../core/widgets/scan_page_image.dart';
import '../../core/widgets/status_views.dart';
import 'crop_screen.dart';
import 'scan_controller.dart';
import 'sheets/export_sheet.dart';
import 'sheets/filter_sheet.dart';
import 'widgets/page_thumbnail.dart';

enum _AddSource { camera, gallery }

/// Reviews one batch: reorder, rotate, crop, filter, then export.
class BatchEditorScreen extends StatefulWidget {
  const BatchEditorScreen({super.key, required this.controller});

  final ScanController controller;

  @override
  State<BatchEditorScreen> createState() => _BatchEditorScreenState();
}

class _BatchEditorScreenState extends State<BatchEditorScreen> {
  ScanController get _controller => widget.controller;

  Future<void> _openCrop() async {
    final page = _controller.currentPage;
    if (page == null) return;
    final index = _controller.currentIndex;
    final crop = await Navigator.of(context).push<Rect>(
      MaterialPageRoute(
        builder: (_) => CropScreen(page: page),
        fullscreenDialog: true,
      ),
    );
    if (crop != null) _controller.setCrop(index, crop);
  }

  Future<void> _openFilters() async {
    final page = _controller.currentPage;
    if (page == null) return;
    final index = _controller.currentIndex;
    final filter = await showFilterSheet(context, selected: page.filter);
    if (filter != null) _controller.setFilter(index, filter);
  }

  Future<void> _addPages() async {
    final source = await showModalBottomSheet<_AddSource>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Capture page'),
              subtitle: const Text('Opens the camera'),
              onTap: () => Navigator.of(context).pop(_AddSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Import from gallery'),
              subtitle: const Text('Select one or more photos'),
              onTap: () => Navigator.of(context).pop(_AddSource.gallery),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (source == null) return;
    if (source == _AddSource.camera) {
      await _controller.addFromCamera();
    } else {
      await _controller.addFromGallery();
    }
    if (mounted && _controller.error != null) {
      showSnack(context, _controller.error!);
    }
  }

  Future<void> _deleteCurrent() async {
    final index = _controller.currentIndex;
    if (_controller.isEmpty) return;
    final confirmed = await confirmDialog(
      context,
      title: 'Delete page?',
      message: 'Removes page ${index + 1} from this batch.',
      confirmLabel: 'Delete',
    );
    if (!confirmed) return;
    _controller.removePage(index);
    if (_controller.isEmpty && mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _export() async {
    if (_controller.isEmpty) return;
    final options = await showExportSheet(
      context,
      pageCount: _controller.pageCount,
    );
    if (options == null || !mounted) return;

    try {
      final result = options.asPdf
          ? await _controller.exportPdf(quality: options.quality)
          : await _controller.exportImages(
              quality: options.quality,
              format: options.format,
            );
      if (!mounted) return;
      await _showSuccess(result);
    } catch (_) {
      if (!mounted) return;
      showSnack(context, _controller.error ?? 'Export failed. Try again.');
    }
  }

  Future<void> _showSuccess(ScanExportResult result) async {
    final paths = result.files.map((file) => file.path).toList(growable: false);
    final message = result.isPdf
        ? 'PDF saved to the Files tab (${_controller.pageCount} pages).'
        : '${paths.length} image${paths.length == 1 ? '' : 's'} saved to the '
              'Files tab.';

    final share = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.check_circle_outline),
        title: const Text('Export complete'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Share'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Done'),
          ),
        ],
      ),
    );

    if (share == true && mounted) {
      await context.read<AppServices>().fileAccess.shareFiles(
        paths,
        subject: result.files.isEmpty ? null : result.files.first.name,
      );
    }
    if (mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final page = _controller.currentPage;
        final count = _controller.pageCount;
        return Scaffold(
          appBar: AppBar(
            title: Text(count == 0 ? 'Batch' : 'Page ${_controller.currentIndex + 1} of $count'),
            actions: [
              IconButton(
                tooltip: 'Delete page',
                onPressed: count == 0 ? null : _deleteCurrent,
                icon: const Icon(Icons.delete_outline),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8, left: 4),
                child: FilledButton.tonal(
                  onPressed: count == 0 || _controller.isBusy ? null : _export,
                  child: const Text('Export'),
                ),
              ),
            ],
          ),
          body: Stack(
            children: [
              Column(
                children: [
                  Expanded(
                    child: page == null
                        ? const EmptyState(
                            icon: Icons.auto_awesome_motion_outlined,
                            title: 'No pages',
                            message: 'Add a page to start editing.',
                          )
                        : Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                            child: Center(
                              child: ScanPageImage(
                                key: ValueKey(page.id),
                                page: page,
                                targetWidth: 1800,
                              ),
                            ),
                          ),
                  ),
                  if (count > 0)
                    SizedBox(
                      height: 104,
                      child: ReorderableListView.builder(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        buildDefaultDragHandles: count > 1,
                        itemCount: count,
                        onReorderItem: _controller.reorder,
                        proxyDecorator: (child, index, animation) =>
                            Material(color: Colors.transparent, child: child),
                        itemBuilder: (context, index) {
                          final item = _controller.pages[index];
                          return Padding(
                            key: ValueKey(item.id),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 6,
                            ),
                            child: PageThumbnail(
                              page: item,
                              index: index,
                              selected: index == _controller.currentIndex,
                              onTap: () => _controller.select(index),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
              if (_controller.isBusy)
                BusyOverlay(
                  message: _controller.busyLabel ?? 'Exporting…',
                  progress: _controller.progress,
                ),
            ],
          ),
          bottomNavigationBar: BottomAppBar(
            height: 72,
            padding: EdgeInsets.zero,
            child: Row(
              children: [
                _ToolButton(
                  icon: Icons.rotate_left,
                  label: 'Left',
                  onTap: page == null
                      ? null
                      : () => _controller.rotateCurrent(clockwise: false),
                ),
                _ToolButton(
                  icon: Icons.rotate_right,
                  label: 'Right',
                  onTap: page == null
                      ? null
                      : () => _controller.rotateCurrent(),
                ),
                _ToolButton(
                  icon: Icons.crop,
                  label: 'Crop',
                  onTap: page == null ? null : _openCrop,
                ),
                _ToolButton(
                  icon: Icons.filter_b_and_w,
                  label: 'Filter',
                  onTap: page == null ? null : _openFilters,
                ),
                _ToolButton(
                  icon: Icons.add_photo_alternate_outlined,
                  label: 'Add',
                  onTap: _controller.isBusy ? null : _addPages,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 24,
              color: enabled ? scheme.onSurface : scheme.onSurface.withValues(alpha: 0.35),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: enabled
                    ? scheme.onSurfaceVariant
                    : scheme.onSurfaceVariant.withValues(alpha: 0.4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
