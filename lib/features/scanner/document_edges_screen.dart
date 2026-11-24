import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/document/document_corners.dart';
import '../../core/models/scan_page.dart';
import '../../core/services/app_services.dart';
import '../../core/widgets/document_quad_overlay.dart';
import '../../core/widgets/scan_page_image.dart';
import '../../core/widgets/status_views.dart';
import 'scan_controller.dart';

/// Corners picked by the user plus the document filter chosen for the page.
class DocumentEdgesResult {
  const DocumentEdgesResult({required this.corners, required this.filter});

  final DocumentCorners corners;
  final ScanFilter filter;
}

/// Opens the edge detector/corner editor for page [index] and applies the
/// result to the batch. Cancelling leaves the page untouched.
Future<void> openDocumentEdges(
  BuildContext context,
  ScanController controller,
  int index,
) async {
  if (index < 0 || index >= controller.pageCount) return;
  final page = controller.pages[index];

  final result = await Navigator.of(context).push<DocumentEdgesResult>(
    MaterialPageRoute(
      builder: (_) => DocumentEdgesScreen(page: page),
      fullscreenDialog: true,
    ),
  );
  if (result == null) return;

  await controller.applyDocumentCorners(
    index,
    result.corners,
    quarterTurns: page.quarterTurns,
    filter: result.filter,
  );
  if (context.mounted && controller.error != null) {
    showSnack(context, controller.error!);
  }
}

/// Zooms in on the photographed page so the four paper corners can be checked
/// and dragged before the perspective warp is applied.
class DocumentEdgesScreen extends StatefulWidget {
  const DocumentEdgesScreen({super.key, required this.page});

  final ScanPage page;

  @override
  State<DocumentEdgesScreen> createState() => _DocumentEdgesScreenState();
}

class _DocumentEdgesScreenState extends State<DocumentEdgesScreen> {
  final TransformationController _zoom = TransformationController();
  final GlobalKey _viewerKey = GlobalKey();

  ui.Image? _image;
  bool _failed = false;
  bool _detecting = true;
  bool _manual = false;
  double _confidence = 0;
  String? _note;
  DocumentCorners _corners = DocumentCorners.fullFrame;
  late ScanFilter _filter = widget.page.filter;

  String get _sourcePath => widget.page.editableSourcePath;

  ScanPage get _previewPage => widget.page.copyWith(
    imagePath: _sourcePath,
    filter: _filter,
    quarterTurns: widget.page.quarterTurns,
  );

  @override
  void initState() {
    super.initState();
    _loadImage();
    _runDetection();
  }

  @override
  void dispose() {
    _zoom.dispose();
    _image?.dispose();
    super.dispose();
  }

  Future<void> _loadImage() async {
    try {
      final image = await decodeScanImage(_sourcePath, targetWidth: 2400);
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() => _image = image);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _runDetection() async {
    setState(() => _detecting = true);
    try {
      final detection = await context.read<AppServices>().documents.detectFile(
        _sourcePath,
      );
      if (!mounted) return;
      _zoom.value = Matrix4.identity();
      setState(() {
        _corners = detection.corners.rotated(widget.page.quarterTurns);
        _confidence = detection.confidence;
        _note = detection.note;
        _manual = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _corners = DocumentCorners.fullFrame;
        _confidence = 0;
        _note = 'Automatic detection failed. Drag the corners to fit the page.';
      });
    } finally {
      if (mounted) setState(() => _detecting = false);
    }
  }

  void _zoomBy(double factor) {
    final size = _viewerKey.currentContext?.size;
    final current = _zoom.value.getMaxScaleOnAxis();
    final next = (current * factor).clamp(1.0, 5.0);
    if (next <= 1.0001) {
      _zoom.value = Matrix4.identity();
      return;
    }
    if (size == null || size.isEmpty) return;

    final delta = next / current;
    final center = Offset(size.width / 2, size.height / 2);
    final zoom = Matrix4.identity()
      ..setEntry(0, 0, delta)
      ..setEntry(1, 1, delta)
      ..setEntry(0, 3, center.dx * (1 - delta))
      ..setEntry(1, 3, center.dy * (1 - delta));
    _zoom.value = zoom * _zoom.value;
  }

  void _apply() {
    Navigator.of(context)
        .pop(DocumentEdgesResult(corners: _corners, filter: _filter));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Adjust edges'),
        actions: [
          IconButton(
            tooltip: 'Detect page automatically',
            onPressed: _detecting ? null : _runDetection,
            icon: _detecting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_fix_high),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(child: _buildPreview()),
            _buildControls(context),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview() {
    if (_failed) {
      return const Center(
        child: Text(
          'Image unavailable',
          style: TextStyle(color: Colors.white70),
        ),
      );
    }
    final image = _image;
    if (image == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: AspectRatio(
              aspectRatio: _aspectRatio(image),
              child: ClipRect(
                child: InteractiveViewer(
                  key: _viewerKey,
                  transformationController: _zoom,
                  // Handled by the overlay: one-finger drags move a corner,
                  // two fingers pinch to zoom.
                  panEnabled: false,
                  minScale: 1,
                  maxScale: 5,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ScanPageImage(
                        page: _previewPage,
                        preloadedImage: image,
                        ignoreCrop: true,
                        backgroundColor: Colors.black,
                      ),
                      DocumentQuadOverlay(
                        corners: _corners,
                        onChanged: (corners) => setState(() {
                          _corners = corners;
                          _manual = true;
                        }),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          right: 24,
          bottom: 16,
          child: _ZoomControls(
            onZoomIn: () => _zoomBy(1.6),
            onZoomOut: () => _zoomBy(0.625),
            onReset: () => _zoom.value = Matrix4.identity(),
          ),
        ),
      ],
    );
  }

  Widget _buildControls(BuildContext context) {
    final theme = Theme.of(context);
    final showWarning = !_detecting && !_manual && _confidence < 0.55;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_detecting) const LinearProgressIndicator(minHeight: 2),
          if (showWarning)
            _Banner(
              icon: Icons.warning_amber_rounded,
              message:
                  _note ??
                  'Edges look uncertain. Drag the corners onto the paper.',
            )
          else if (!_detecting && _note != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                _note!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          const SizedBox(height: 10),
          Text('Filter', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: ScanFilter.values
                .map(
                  (filter) => ChoiceChip(
                    label: Text(filter.label),
                    selected: _filter == filter,
                    onSelected: (_) => setState(() => _filter = filter),
                  ),
                )
                .toList(growable: false),
          ),
          const SizedBox(height: 8),
          Text(
            'Drag a corner onto the paper edge. Pinch or use + / − to zoom. '
            'The filter is applied after the page is straightened.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _detecting
                      ? null
                      : () {
                          setState(() {
                            _corners = DocumentCorners.fullFrame;
                            _manual = true;
                          });
                          _zoom.value = Matrix4.identity();
                        },
                  icon: const Icon(Icons.fullscreen),
                  label: const Text('Full page'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _detecting || !_corners.isValid ? null : _apply,
                  child: const Text('Apply'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  double _aspectRatio(ui.Image image) {
    final width = image.width.toDouble();
    final height = image.height.toDouble();
    return widget.page.quarterTurns.isOdd ? height / width : width / height;
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: scheme.onSecondaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSecondaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _ZoomControls extends StatelessWidget {
  const _ZoomControls({
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onReset,
  });

  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(22),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Zoom in',
            onPressed: onZoomIn,
            color: Colors.white,
            iconSize: 20,
            icon: const Icon(Icons.add),
          ),
          IconButton(
            tooltip: 'Zoom out',
            onPressed: onZoomOut,
            color: Colors.white,
            iconSize: 20,
            icon: const Icon(Icons.remove),
          ),
          IconButton(
            tooltip: 'Fit to screen',
            onPressed: onReset,
            color: Colors.white,
            iconSize: 18,
            icon: const Icon(Icons.fit_screen_outlined),
          ),
        ],
      ),
    );
  }
}
