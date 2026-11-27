import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/document/document_corners.dart';
import '../../core/models/scan_page.dart';
import '../../core/services/app_services.dart';
import '../../core/widgets/corner_loupe.dart';
import '../../core/widgets/document_quad_overlay.dart';
import '../../core/widgets/scan_page_image.dart';
import '../../core/widgets/status_views.dart';
import 'scan_controller.dart';

/// Corners picked by the user plus the page rotation and filter to apply.
class DocumentEdgesResult {
  const DocumentEdgesResult({
    required this.corners,
    required this.filter,
    required this.quarterTurns,
  });

  final DocumentCorners corners;
  final ScanFilter filter;

  /// Clockwise quarter turns chosen in the editor, relative to the source
  /// photo. Passed to the warp so the crop and the rotation are baked in one
  /// step.
  final int quarterTurns;
}

/// Opens the post-capture corner editor for page [index] and applies the
/// confirmed crop to the batch. Cancelling leaves the page untouched.
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
    quarterTurns: result.quarterTurns,
    filter: result.filter,
  );
  if (context.mounted && controller.error != null) {
    showSnack(context, controller.error!);
  }
}

/// Post-capture corner adjustment.
///
/// The full-resolution photo is decoded for the preview and never modified
/// here: the four handles simply describe a quad in normalized image
/// coordinates, and the perspective warp runs only after the user confirms.
/// Auto-detected corners seed the handles; when detection fails or looks
/// unreliable the editor falls back to a sensible inset rectangle (or the full
/// frame if even that is not possible).
class DocumentEdgesScreen extends StatefulWidget {
  const DocumentEdgesScreen({super.key, required this.page});

  final ScanPage page;

  @override
  State<DocumentEdgesScreen> createState() => _DocumentEdgesScreenState();
}

class _DocumentEdgesScreenState extends State<DocumentEdgesScreen> {
  final TransformationController _zoom = TransformationController();
  final GlobalKey _viewerKey = GlobalKey();

  static const double _loupeDiameter = 116;

  ui.Image? _image;
  bool _failed = false;
  bool _detecting = true;
  bool _manual = false;
  double _confidence = 0;
  String? _note;
  int? _activeCorner;
  int _quarterTurns = 0;

  /// Auto-detected corners in the orientation currently on screen; used by the
  /// Reset action. Null when detection failed.
  DocumentCorners? _detectedCorners;

  DocumentCorners _corners = DocumentCorners.fullFrame;
  late ScanFilter _filter = widget.page.filter;

  String get _sourcePath => widget.page.editableSourcePath;

  ScanPage get _previewPage => widget.page.copyWith(
    imagePath: _sourcePath,
    filter: _filter,
    quarterTurns: _quarterTurns,
  );

  @override
  void initState() {
    super.initState();
    _quarterTurns = widget.page.quarterTurns % 4;
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
      // Detection can return a degenerate quad on very noisy photos; the
      // handles still need a usable starting outline, so fall back to the
      // whole image in that case.
      final detected = detection.corners.rotated(_quarterTurns);
      final corners = detected.isValid ? detected : DocumentCorners.fullFrame;
      setState(() {
        _detectedCorners = corners;
        _corners = corners;
        _confidence = detection.confidence;
        _note = detection.note;
        _manual = false;
      });
    } catch (_) {
      if (!mounted) return;
      _zoom.value = Matrix4.identity();
      setState(() {
        _detectedCorners = null;
        _corners = DocumentCorners.fullFrame;
        _confidence = 0;
        _note = 'Automatic detection failed. Drag the corners to fit the page.';
        _manual = false;
      });
    } finally {
      if (mounted) setState(() => _detecting = false);
    }
  }

  void _resetCorners() {
    setState(() {
      _corners = _detectedCorners ?? DocumentCorners.fullFrame;
      _manual = false;
    });
    _zoom.value = Matrix4.identity();
  }

  void _selectFullImage() {
    setState(() {
      _corners = DocumentCorners.fullFrame;
      _manual = true;
    });
  }

  /// Rotates the source photo a quarter turn clockwise. The handles rotate with
  /// it, so any manual adjustment is kept in the new orientation.
  void _rotate() {
    setState(() {
      _quarterTurns = (_quarterTurns + 1) % 4;
      _corners = _corners.rotatedClockwise();
      _detectedCorners = _detectedCorners?.rotatedClockwise();
    });
    _zoom.value = Matrix4.identity();
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

  void _cancel() => Navigator.of(context).pop();

  void _confirm() {
    Navigator.of(context).pop(
      DocumentEdgesResult(
        corners: _corners,
        filter: _filter,
        quarterTurns: _quarterTurns,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF11100F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF11100F),
        foregroundColor: Colors.white,
        title: const Text('Adjust page edges'),
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
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final size = constraints.biggest;
                      return Stack(
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
                            onActiveCornerChanged: (index) {
                              if (_activeCorner == index) return;
                              setState(() => _activeCorner = index);
                            },
                          ),
                          if (_activeCorner != null)
                            _buildLoupe(size, image),
                        ],
                      );
                    },
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

  /// Places the magnifier near the active corner. The loupe lives inside the
  /// zoomed viewer, so it is counter-scaled by the current zoom to stay a
  /// constant size on screen while still tracking the handle exactly.
  Widget _buildLoupe(Size size, ui.Image image) {
    final index = _activeCorner;
    if (index == null) return const SizedBox.shrink();

    final corner = Offset(
      _corners.points[index].dx * size.width,
      _corners.points[index].dy * size.height,
    );

    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _zoom,
          builder: (context, _) {
            final zoom = _zoom.value.getMaxScaleOnAxis().clamp(1.0, 5.0);
            final half = _loupeDiameter / 2 / zoom;
            final lift = 88.0 / zoom;
            // A corner in the lower half is dragged with the thumb; show the
            // loupe above it. Near the top, put it below.
            final dy = corner.dy > size.height * 0.45 ? -lift : lift;
            final center = Offset(
              corner.dx.clamp(half, size.width - half),
              (corner.dy + dy).clamp(half, size.height - half),
            );

            return Stack(
              children: [
                Positioned(
                  left: center.dx - _loupeDiameter / 2,
                  top: center.dy - _loupeDiameter / 2,
                  width: _loupeDiameter,
                  height: _loupeDiameter,
                  child: Transform.scale(
                    scale: 1 / zoom,
                    child: CornerLoupe(
                      imageSize: size,
                      point: corner,
                      diameter: _loupeDiameter,
                      child: ScanPageImage(
                        page: _previewPage,
                        preloadedImage: image,
                        ignoreCrop: true,
                        backgroundColor: Colors.black,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildControls(BuildContext context) {
    final theme = Theme.of(context);
    final hintColor = Colors.white70;
    final showWarning = !_detecting && !_manual && _confidence < 0.55;

    return Container(
      color: const Color(0xFF11100F),
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
                style: theme.textTheme.bodySmall?.copyWith(color: hintColor),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _QuickAction(
                  icon: Icons.restart_alt,
                  label: 'Reset',
                  onTap: _detecting || _detectedCorners == null
                      ? null
                      : _resetCorners,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _QuickAction(
                  icon: Icons.fullscreen,
                  label: 'Full image',
                  selected: _corners.isFullFrame,
                  onTap: _detecting ? null : _selectFullImage,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _QuickAction(
                  icon: Icons.rotate_right,
                  label: 'Rotate',
                  onTap: _detecting ? null : _rotate,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Filter',
            style: theme.textTheme.titleSmall?.copyWith(color: Colors.white),
          ),
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
            'Drag a handle onto the paper edge — a magnifier appears so your '
            'finger does not cover the corner. Pinch or use + / − to zoom.',
            style: theme.textTheme.bodySmall?.copyWith(color: hintColor),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _cancel,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white38),
                    minimumSize: const Size(0, 48),
                  ),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _detecting || !_corners.isValid ? null : _confirm,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 48),
                  ),
                  child: const Text('Confirm'),
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
    return _quarterTurns.isOdd ? height / width : width / height;
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.label,
    this.onTap,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final color = !enabled
        ? Colors.white30
        : selected
        ? Theme.of(context).colorScheme.primary
        : Colors.white;
    return Material(
      color: Colors.white.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: color),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(fontSize: 11.5, color: color),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
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
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSecondaryContainer,
              ),
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
