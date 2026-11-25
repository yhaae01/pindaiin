import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../document/document_corners.dart';
import '../document/preview_mapping.dart';

/// Live overlay for the camera preview: a dimmed outside area, the detected
/// page outline and corner brackets.
///
/// Corners are already in the displayed orientation (the tracker rotates them
/// once per frame); [PreviewViewportMapping] scales them to the viewport using
/// the same `BoxFit.cover` geometry as the preview itself. The widget is
/// non-interactive: fine-tuning happens after capture in the edge editor.
class LiveQuadOverlay extends StatelessWidget {
  const LiveQuadOverlay({
    super.key,
    required this.corners,
    required this.frameSize,
    required this.quarterTurns,
    this.confidence = 0,
    this.stable = false,
    this.accent,
  });

  final DocumentCorners? corners;
  final Size frameSize;
  final int quarterTurns;
  final double confidence;
  final bool stable;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final color = accent ?? Theme.of(context).colorScheme.primary;
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          return CustomPaint(
            size: constraints.biggest,
            painter: LiveQuadPainter(
              corners: corners,
              frameSize: frameSize,
              quarterTurns: quarterTurns,
              confidence: confidence,
              stable: stable,
              accent: color,
            ),
          );
        },
      ),
    );
  }
}

/// Paints the live detection feedback. Public so tests and previews can use it.
class LiveQuadPainter extends CustomPainter {
  const LiveQuadPainter({
    required this.corners,
    required this.frameSize,
    required this.quarterTurns,
    required this.confidence,
    required this.stable,
    required this.accent,
  });

  final DocumentCorners? corners;
  final Size frameSize;
  final int quarterTurns;
  final double confidence;
  final bool stable;
  final Color accent;

  static const Color _stableColor = Color(0xFF34D399);
  static const Color _uncertainColor = Color(0xFFFBBF24);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final quad = corners;
    if (quad == null) {
      _paintGuide(canvas, size);
      return;
    }

    final mapping = PreviewViewportMapping(
      frameSize: frameSize,
      quarterTurns: quarterTurns,
      viewport: size,
    );
    final points = mapping.mapCorners(quad);
    final path = Path()
      ..moveTo(points[0].dx, points[0].dy)
      ..lineTo(points[1].dx, points[1].dy)
      ..lineTo(points[2].dx, points[2].dy)
      ..lineTo(points[3].dx, points[3].dy)
      ..close();

    final outline = stable
        ? _stableColor
        : confidence >= 0.55
        ? Colors.white
        : _uncertainColor;

    if (!quad.isFullFrame) {
      canvas.drawPath(
        Path.combine(
          PathOperation.difference,
          Path()..addRect(Offset.zero & size),
          path,
        ),
        Paint()..color = Colors.black.withValues(alpha: 0.42),
      );
    }

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeJoin = StrokeJoin.round
        ..color = Colors.black.withValues(alpha: 0.35),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeJoin = StrokeJoin.round
        ..color = outline,
    );

    _paintCorners(canvas, points, outline);
  }

  void _paintCorners(Canvas canvas, List<Offset> points, Color color) {
    const length = 22.0;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..color = color;

    for (var index = 0; index < 4; index++) {
      final point = points[index];
      final next = points[(index + 1) % 4];
      final previous = points[(index + 3) % 4];
      final toNext = _unit(next - point) * length;
      final toPrevious = _unit(previous - point) * length;
      canvas.drawLine(point, point + toNext, paint);
      canvas.drawLine(point, point + toPrevious, paint);

      canvas.drawCircle(
        point,
        3,
        Paint()..color = color.withValues(alpha: 0.85),
      );
    }
  }

  void _paintGuide(Canvas canvas, Size size) {
    final guide = Rect.fromLTRB(
      size.width * 0.08,
      size.height * 0.1,
      size.width * 0.92,
      size.height * 0.9,
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.white.withValues(alpha: 0.55);
    final radius = Radius.circular(math.min(guide.width, guide.height) * 0.06);
    canvas.drawRRect(RRect.fromRectAndRadius(guide, radius), paint);

    final accentPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..color = accent.withValues(alpha: 0.85);
    const length = 26.0;
    final corners = <Offset>[
      guide.topLeft,
      guide.topRight,
      guide.bottomRight,
      guide.bottomLeft,
    ];
    for (var index = 0; index < 4; index++) {
      final point = corners[index];
      final horizontal = Offset(
        index == 0 || index == 3 ? length : -length,
        0,
      );
      final vertical = Offset(
        0,
        index < 2 ? length : -length,
      );
      canvas.drawLine(point, point + horizontal, accentPaint);
      canvas.drawLine(point, point + vertical, accentPaint);
    }
  }

  static Offset _unit(Offset value) {
    final length = value.distance;
    if (length <= 0.0001) return Offset.zero;
    return value / length;
  }

  @override
  bool shouldRepaint(covariant LiveQuadPainter oldDelegate) {
    return oldDelegate.corners != corners ||
        oldDelegate.frameSize != frameSize ||
        oldDelegate.quarterTurns != quarterTurns ||
        oldDelegate.confidence != confidence ||
        oldDelegate.stable != stable ||
        oldDelegate.accent != accent;
  }
}
