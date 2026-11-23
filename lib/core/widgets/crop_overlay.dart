import 'package:flutter/material.dart';

/// Interactive crop rectangle with four corner handles and drag-to-move.
///
/// The rect is normalized (0..1) so it can be stored on [ScanPage] and reused
/// at full resolution on export.
class CropOverlay extends StatefulWidget {
  const CropOverlay({
    super.key,
    required this.crop,
    required this.onChanged,
  });

  final Rect crop;
  final ValueChanged<Rect> onChanged;

  @override
  State<CropOverlay> createState() => _CropOverlayState();
}

enum _DragMode { none, topLeft, topRight, bottomLeft, bottomRight, move }

class _CropOverlayState extends State<CropOverlay> {
  static const double _handleHitRadius = 32;
  static const double _minSize = 0.06;

  _DragMode _mode = _DragMode.none;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (details) {
            setState(() => _mode = _hitTest(details.localPosition, size));
          },
          onPanUpdate: (details) {
            if (_mode == _DragMode.none) return;
            final delta = Offset(
              details.delta.dx / size.width,
              details.delta.dy / size.height,
            );
            widget.onChanged(_apply(delta));
          },
          onPanEnd: (_) => setState(() => _mode = _DragMode.none),
          onPanCancel: () => setState(() => _mode = _DragMode.none),
          child: CustomPaint(
            painter: _CropPainter(crop: widget.crop, accent: accent),
          ),
        );
      },
    );
  }

  _DragMode _hitTest(Offset point, Size size) {
    final crop = widget.crop;
    final rect = Rect.fromLTRB(
      crop.left * size.width,
      crop.top * size.height,
      crop.right * size.width,
      crop.bottom * size.height,
    );

    Offset corner(_DragMode mode, Offset at) => at;

    final corners = <_DragMode, Offset>{
      _DragMode.topLeft: corner(_DragMode.topLeft, rect.topLeft),
      _DragMode.topRight: corner(_DragMode.topRight, rect.topRight),
      _DragMode.bottomLeft: corner(_DragMode.bottomLeft, rect.bottomLeft),
      _DragMode.bottomRight: corner(_DragMode.bottomRight, rect.bottomRight),
    };

    for (final entry in corners.entries) {
      if ((entry.value - point).distance <= _handleHitRadius) return entry.key;
    }
    if (rect.contains(point)) return _DragMode.move;
    return _DragMode.none;
  }

  Rect _apply(Offset delta) {
    final crop = widget.crop;
    var left = crop.left;
    var top = crop.top;
    var right = crop.right;
    var bottom = crop.bottom;

    switch (_mode) {
      case _DragMode.topLeft:
        left = (left + delta.dx).clamp(0.0, right - _minSize);
        top = (top + delta.dy).clamp(0.0, bottom - _minSize);
      case _DragMode.topRight:
        right = (right + delta.dx).clamp(left + _minSize, 1.0);
        top = (top + delta.dy).clamp(0.0, bottom - _minSize);
      case _DragMode.bottomLeft:
        left = (left + delta.dx).clamp(0.0, right - _minSize);
        bottom = (bottom + delta.dy).clamp(top + _minSize, 1.0);
      case _DragMode.bottomRight:
        right = (right + delta.dx).clamp(left + _minSize, 1.0);
        bottom = (bottom + delta.dy).clamp(top + _minSize, 1.0);
      case _DragMode.move:
        final dx = delta.dx.clamp(-left, 1.0 - right);
        final dy = delta.dy.clamp(-top, 1.0 - bottom);
        left += dx;
        right += dx;
        top += dy;
        bottom += dy;
      case _DragMode.none:
        return crop;
    }

    return Rect.fromLTRB(left, top, right, bottom);
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter({required this.crop, required this.accent});

  final Rect crop;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTRB(
      crop.left * size.width,
      crop.top * size.height,
      crop.right * size.width,
      crop.bottom * size.height,
    );

    // Dim everything outside the crop.
    final overlay = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      Path()..addRect(rect),
    );
    canvas.drawPath(overlay, Paint()..color = Colors.black.withValues(alpha: 0.55));

    // Rule-of-thirds guides.
    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..strokeWidth = 0.7;
    for (var i = 1; i < 3; i++) {
      final dx = rect.left + rect.width * i / 3;
      final dy = rect.top + rect.height * i / 3;
      canvas.drawLine(Offset(dx, rect.top), Offset(dx, rect.bottom), gridPaint);
      canvas.drawLine(Offset(rect.left, dy), Offset(rect.right, dy), gridPaint);
    }

    // Border.
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white.withValues(alpha: 0.9),
    );

    // Corner handles (L-shapes).
    final handlePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.square
      ..color = accent;
    const arm = 22.0;
    void corner(Offset at, double sx, double sy) {
      canvas.drawLine(at, at + Offset(arm * sx, 0), handlePaint);
      canvas.drawLine(at, at + Offset(0, arm * sy), handlePaint);
    }

    corner(rect.topLeft, 1, 1);
    corner(rect.topRight, -1, 1);
    corner(rect.bottomLeft, 1, -1);
    corner(rect.bottomRight, -1, -1);
  }

  @override
  bool shouldRepaint(covariant _CropPainter oldDelegate) =>
      oldDelegate.crop != crop || oldDelegate.accent != accent;
}
