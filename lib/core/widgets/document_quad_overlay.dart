import 'package:flutter/material.dart';

import '../document/document_corners.dart';

/// Four draggable corner handles over the page preview.
///
/// Corner positions are normalized, so the same widget works on the zoomed
/// preview and maps directly to full-resolution pixels at warp time. Pointer
/// events are used instead of gesture recognizers so the surrounding
/// [InteractiveViewer] still handles pinch-to-zoom.
class DocumentQuadOverlay extends StatefulWidget {
  const DocumentQuadOverlay({
    super.key,
    required this.corners,
    required this.onChanged,
    this.accent,
    this.hitRadius = 36,
  });

  final DocumentCorners corners;
  final ValueChanged<DocumentCorners> onChanged;
  final Color? accent;
  final double hitRadius;

  @override
  State<DocumentQuadOverlay> createState() => _DocumentQuadOverlayState();
}

class _DocumentQuadOverlayState extends State<DocumentQuadOverlay> {
  int? _activeCorner;
  int? _pointer;
  DocumentCorners? _draft;

  @override
  void didUpdateWidget(covariant DocumentQuadOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_activeCorner == null) _draft = null;
  }

  void _onPointerDown(
    PointerDownEvent event,
    Size size,
    DocumentCorners corners,
  ) {
    if (_pointer != null) return;
    final scaled = corners.scaledTo(size);
    var best = -1;
    var bestDistance = double.infinity;

    for (var index = 0; index < 4; index++) {
      final distance = (scaled.points[index] - event.localPosition).distance;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = index;
      }
    }
    if (best < 0 || bestDistance > widget.hitRadius) return;

    setState(() {
      _pointer = event.pointer;
      _activeCorner = best;
      _draft = corners;
    });
  }

  void _onPointerMove(PointerMoveEvent event, Size size) {
    final corner = _activeCorner;
    final draft = _draft;
    if (corner == null || draft == null || event.pointer != _pointer) return;

    // localDelta keeps dragging accurate while the preview is zoomed.
    final delta = Offset(
      size.width == 0 ? 0 : event.localDelta.dx / size.width,
      size.height == 0 ? 0 : event.localDelta.dy / size.height,
    );
    final candidate = draft
        .withPoint(corner, draft.points[corner] + delta)
        .clampedToFrame();
    if (!candidate.isValid) return;

    _draft = candidate;
    widget.onChanged(candidate);
  }

  void _endDrag(PointerEvent event) {
    if (event.pointer != _pointer) return;
    setState(() {
      _pointer = null;
      _activeCorner = null;
      _draft = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final corners = _draft ?? widget.corners;
    final accent = widget.accent ?? Theme.of(context).colorScheme.primary;

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (event) => _onPointerDown(event, size, corners),
          onPointerMove: (event) => _onPointerMove(event, size),
          onPointerUp: _endDrag,
          onPointerCancel: _endDrag,
          child: CustomPaint(
            painter: DocumentQuadPainter(corners: corners, accent: accent),
          ),
        );
      },
    );
  }
}

/// Paints the dimmed outside area, the page outline and the corner handles.
class DocumentQuadPainter extends CustomPainter {
  const DocumentQuadPainter({required this.corners, required this.accent});

  final DocumentCorners corners;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final points = corners.scaledTo(size).points;
    final quad = Path()
      ..moveTo(points[0].dx, points[0].dy)
      ..lineTo(points[1].dx, points[1].dy)
      ..lineTo(points[2].dx, points[2].dy)
      ..lineTo(points[3].dx, points[3].dy)
      ..close();

    // Everything outside the detected paper is background to be cropped.
    final outside = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      quad,
    );
    canvas.drawPath(
      outside,
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );

    canvas.drawPath(
      quad,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..color = Colors.white.withValues(alpha: 0.95),
    );
    canvas.drawPath(
      quad,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = accent.withValues(alpha: 0.9),
    );

    for (final point in points) {
      canvas.drawCircle(
        point,
        18,
        Paint()
          ..style = PaintingStyle.fill
          ..color = Colors.black.withValues(alpha: 0.25),
      );
      canvas.drawCircle(
        point,
        11,
        Paint()
          ..style = PaintingStyle.fill
          ..color = Colors.white,
      );
      canvas.drawCircle(
        point,
        7,
        Paint()
          ..style = PaintingStyle.fill
          ..color = accent,
      );
    }
  }

  @override
  bool shouldRepaint(covariant DocumentQuadPainter oldDelegate) =>
      oldDelegate.corners != corners || oldDelegate.accent != accent;
}
