import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/document/preview_mapping.dart';
import '../../../core/services/app_services.dart';
import '../../../core/widgets/live_quad_overlay.dart';
import '../../../core/widgets/status_views.dart';
import '../document_edges_screen.dart';
import '../scan_controller.dart';
import '../widgets/page_thumbnail.dart';
import 'live_scan_controller.dart';

/// Live camera scanner: real-time page detection on the preview, manual or
/// automatic capture, and multi-page accumulation into the batch.
///
/// Returns `true` when the user asked to fall back to the system camera because
/// the in-app camera could not be opened.
class LiveScanScreen extends StatefulWidget {
  const LiveScanScreen({super.key, required this.controller});

  final ScanController controller;

  @override
  State<LiveScanScreen> createState() => _LiveScanScreenState();
}

class _LiveScanScreenState extends State<LiveScanScreen> {
  late final LiveScanController _live;
  CapturedPageResult? _lastAdded;
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _live = LiveScanController(
      services: context.read<AppServices>(),
      batch: widget.controller,
    )..onPageAdded = _handlePageAdded;
    unawaited(_live.initialize());
  }

  @override
  void dispose() {
    _live.onPageAdded = null;
    _live.dispose();
    super.dispose();
  }

  void _handlePageAdded(CapturedPageResult result) {
    if (!mounted) return;
    setState(() => _lastAdded = result);
    // Automatic detection was not usable for this shot: go straight to the
    // corner editor so the page can be fixed before scanning the next one.
    // Cancelling there keeps the uncropped photo in the batch.
    if (result.needsEdgeReview) unawaited(_adjustEdges(result));
  }

  Future<void> _adjustEdges(CapturedPageResult result) async {
    if (_editing) return;
    setState(() => _editing = true);
    await _live.pause();
    if (!mounted) return;
    await openDocumentEdges(context, widget.controller, result.index);
    if (!mounted) return;
    await _live.resume();
    if (mounted) setState(() => _lastAdded = null);
    _editing = false;
  }

  void _useSystemCamera() {
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_live, widget.controller]),
      builder: (context, _) {
        return Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            fit: StackFit.expand,
            children: [
              _buildPreview(),
              const _EdgeGradient(alignment: Alignment.topCenter),
              const _EdgeGradient(alignment: Alignment.bottomCenter),
              SafeArea(child: _buildChrome(context)),
              if (_live.isCapturing) const BusyOverlay(message: 'Saving page…'),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPreview() {
    if (_live.error != null) return const ColoredBox(color: Colors.black);
    if (!_live.isReady) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white70),
      );
    }
    final camera = _live.camera!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final mapping = PreviewViewportMapping(
          frameSize: _live.frameSize,
          quarterTurns: _live.quarterTurns,
          viewport: constraints.biggest,
        );
        return ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fromRect(
                rect: mapping.displayRect,
                child: CameraPreview(camera),
              ),
              LiveQuadOverlay(
                corners: _live.update.corners,
                frameSize: _live.frameSize,
                quarterTurns: _live.quarterTurns,
                confidence: _live.update.confidence,
                stable: _live.update.stable,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildChrome(BuildContext context) {
    return Column(
      children: [
        _TopBar(
          pageCount: widget.controller.pageCount,
          torchOn: _live.torchOn,
          autoCapture: _live.autoCapture,
          busy: _live.isCapturing,
          onClose: () => Navigator.of(context).pop(false),
          onTorch: _live.toggleTorch,
          onAutoCapture: () => _live.setAutoCapture(!_live.autoCapture),
        ),
        if (_live.error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: _CameraErrorPanel(
              message: _live.error!,
              onRetry: _live.initialize,
              onUseSystemCamera: _useSystemCamera,
            ),
          ),
        if (_live.warning != null && _live.error == null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: _InfoBanner(message: _live.warning!),
          ),
        if (_live.lastCaptureError != null && _live.error == null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: _InfoBanner(
              message: _live.lastCaptureError!,
              error: true,
            ),
          ),
        const Spacer(),
        if (widget.controller.pageCount > 0) _buildPageStrip(),
        if (_lastAdded != null)
          _CaptureFeedback(
            result: _lastAdded!,
            busy: _editing,
            onAdjust: () => _adjustEdges(_lastAdded!),
            onDismiss: () => setState(() => _lastAdded = null),
          ),
        if (_live.error == null) _buildStatusChip(context),
        const SizedBox(height: 12),
        if (_live.error == null) _buildControls(),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _buildPageStrip() {
    final pages = widget.controller.pages;
    final visible = pages.length > 6 ? pages.sublist(pages.length - 6) : pages;
    final firstIndex = pages.length - visible.length;
    return SizedBox(
      height: 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: visible.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, index) => PageThumbnail(
          page: visible[index],
          index: firstIndex + index,
          width: 42,
          height: 54,
        ),
      ),
    );
  }

  Widget _buildStatusChip(BuildContext context) {
    final update = _live.update;
    final String label;
    final Color color;
    final IconData icon;

    if (_live.isCapturing) {
      label = 'Saving page…';
      color = Colors.white70;
      icon = Icons.hourglass_top;
    } else if (update.stable) {
      label = _live.autoCapture
          ? 'Ready — capturing automatically'
          : 'Ready — tap the shutter';
      color = const Color(0xFF34D399);
      icon = Icons.check_circle_outline;
    } else if (update.hasDocument && update.isConfident) {
      label = 'Page detected — hold steady';
      color = Colors.white;
      icon = Icons.crop_free;
    } else if (update.hasDocument) {
      label = 'Edges unclear — move closer or add light';
      color = const Color(0xFFFBBF24);
      icon = Icons.warning_amber_rounded;
    } else {
      label = 'Point the camera at a page';
      color = Colors.white70;
      icon = Icons.center_focus_strong_outlined;
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              style: TextStyle(color: color, fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControls() {
    final enabled = _live.isReady && !_live.isCapturing && !_editing;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _RoundIconButton(
            icon: _live.autoCapture
                ? Icons.auto_awesome
                : Icons.auto_awesome_outlined,
            label: 'Auto',
            active: _live.autoCapture,
            onTap: enabled
                ? () => _live.setAutoCapture(!_live.autoCapture)
                : null,
          ),
          _ShutterButton(
            enabled: enabled,
            capturing: _live.isCapturing,
            onTap: enabled ? () => unawaited(_live.capture()) : null,
          ),
          _RoundIconButton(
            icon: _live.torchOn ? Icons.flashlight_on : Icons.flashlight_off,
            label: 'Light',
            active: _live.torchOn,
            onTap: enabled ? _live.toggleTorch : null,
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.pageCount,
    required this.torchOn,
    required this.autoCapture,
    required this.busy,
    required this.onClose,
    required this.onTorch,
    required this.onAutoCapture,
  });

  final int pageCount;
  final bool torchOn;
  final bool autoCapture;
  final bool busy;
  final VoidCallback onClose;
  final VoidCallback onTorch;
  final VoidCallback onAutoCapture;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 0),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Close scanner',
            onPressed: busy ? null : onClose,
            icon: const Icon(Icons.close, color: Colors.white),
          ),
          Expanded(
            child: Text(
              pageCount == 0 ? 'Scan page' : '$pageCount page${pageCount == 1 ? '' : 's'} captured',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            tooltip: autoCapture ? 'Disable auto-capture' : 'Enable auto-capture',
            onPressed: busy ? null : onAutoCapture,
            icon: Icon(
              autoCapture ? Icons.auto_awesome : Icons.auto_awesome_outlined,
              color: autoCapture ? const Color(0xFF34D399) : Colors.white,
            ),
          ),
          IconButton(
            tooltip: torchOn ? 'Turn flashlight off' : 'Turn flashlight on',
            onPressed: busy ? null : onTorch,
            icon: Icon(
              torchOn ? Icons.flashlight_on : Icons.flashlight_off,
              color: torchOn ? const Color(0xFFFBBF24) : Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

class _ShutterButton extends StatelessWidget {
  const _ShutterButton({
    required this.enabled,
    required this.capturing,
    this.onTap,
  });

  final bool enabled;
  final bool capturing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Capture page',
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: Container(
          width: 78,
          height: 78,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: enabled ? Colors.white : Colors.white38,
              width: 4,
            ),
          ),
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              width: capturing ? 34 : 60,
              height: capturing ? 34 : 60,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: enabled ? Colors.white : Colors.white38,
              ),
              child: capturing
                  ? const Padding(
                      padding: EdgeInsets.all(8),
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Colors.black54,
                      ),
                    )
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.icon,
    required this.label,
    required this.active,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: active ? const Color(0xFF0F766E) : Colors.black45,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              width: 48,
              height: 48,
              child: Icon(
                icon,
                size: 22,
                color: enabled ? Colors.white : Colors.white38,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            color: enabled ? Colors.white70 : Colors.white30,
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}

class _CaptureFeedback extends StatelessWidget {
  const _CaptureFeedback({
    required this.result,
    required this.busy,
    required this.onAdjust,
    required this.onDismiss,
  });

  final CapturedPageResult result;
  final bool busy;
  final VoidCallback onAdjust;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final uncertain = result.needsEdgeReview;
    final color = uncertain ? const Color(0xFFFBBF24) : const Color(0xFF34D399);
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 4, 20, 10),
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(
            uncertain ? Icons.warning_amber_rounded : Icons.check_circle_outline,
            color: color,
            size: 20,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              uncertain
                  ? 'Page ${result.index + 1} added — edges were not clear.'
                  : 'Page ${result.index + 1} straightened and added.',
              style: const TextStyle(color: Colors.white, fontSize: 12.5),
            ),
          ),
          if (uncertain)
            TextButton(
              onPressed: busy ? null : onAdjust,
              child: const Text('Adjust'),
            ),
          IconButton(
            tooltip: 'Dismiss',
            onPressed: busy ? null : onDismiss,
            icon: const Icon(Icons.close, size: 18, color: Colors.white70),
          ),
        ],
      ),
    );
  }
}

class _CameraErrorPanel extends StatelessWidget {
  const _CameraErrorPanel({
    required this.message,
    required this.onRetry,
    required this.onUseSystemCamera,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onUseSystemCamera;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF1C1B1F),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.no_photography_outlined, color: Colors.white70),
            const SizedBox(height: 8),
            const Text(
              'Camera unavailable',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: onRetry,
                  child: const Text('Try again'),
                ),
                OutlinedButton(
                  onPressed: onUseSystemCamera,
                  child: const Text('Use system camera'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoBanner extends StatelessWidget {
  const _InfoBanner({required this.message, this.error = false});

  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: error
            ? Border.all(color: const Color(0xFFF87171).withValues(alpha: 0.7))
            : null,
      ),
      child: Row(
        children: [
          Icon(
            error ? Icons.error_outline : Icons.info_outline,
            size: 16,
            color: error ? const Color(0xFFF87171) : Colors.white70,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: error ? const Color(0xFFFCA5A5) : Colors.white70,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EdgeGradient extends StatelessWidget {
  const _EdgeGradient({required this.alignment});

  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final top = alignment == Alignment.topCenter;
    return Align(
      alignment: alignment,
      child: IgnorePointer(
        child: Container(
          height: top ? 150 : 290,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: top ? Alignment.topCenter : Alignment.bottomCenter,
              end: top ? Alignment.bottomCenter : Alignment.topCenter,
              colors: [
                Colors.black.withValues(alpha: 0.55),
                Colors.transparent,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
