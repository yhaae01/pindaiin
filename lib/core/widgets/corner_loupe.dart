import 'package:flutter/material.dart';

/// Circular magnifier that shows the image under an actively dragged corner.
///
/// It is placed a little away from the finger so the paper edge stays visible
/// while the handle is moved. The magnified content is the same image widget
/// the editor shows ([child]), transformed with a simple scale-and-translate
/// matrix, so no second decode or duplicated painting logic is needed.
///
/// [point] is in the coordinate space of [child] (the displayed image widget),
/// which keeps the loupe correct for any preview size or PDF-style rotation.
class CornerLoupe extends StatelessWidget {
  const CornerLoupe({
    super.key,
    required this.child,
    required this.imageSize,
    required this.point,
    this.diameter = 116,
    this.magnification = 3,
    this.accent = Colors.white,
  });

  /// The preview image widget, laid out at [imageSize].
  final Widget child;

  /// Size of the displayed image widget in logical pixels.
  final Size imageSize;

  /// Active corner position in the coordinate space of [imageSize].
  final Offset point;

  final double diameter;

  /// How much the loupe zooms relative to the on-screen preview.
  final double magnification;

  final Color accent;

  @override
  Widget build(BuildContext context) {
    // Places `point` at the centre of the loupe, magnified.
    final transform = Matrix4.identity()
      ..setEntry(0, 0, magnification)
      ..setEntry(1, 1, magnification)
      ..setEntry(0, 3, diameter / 2 - point.dx * magnification)
      ..setEntry(1, 3, diameter / 2 - point.dy * magnification);

    return IgnorePointer(
      child: Container(
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: accent, width: 2),
          boxShadow: const [
            BoxShadow(color: Color(0x66000000), blurRadius: 12),
          ],
        ),
        child: ClipOval(
          child: Stack(
            fit: StackFit.expand,
            children: [
              // The image is bigger than the loupe; OverflowBox keeps it from
              // being shrunk by the Stack's constraints.
              OverflowBox(
                alignment: Alignment.topLeft,
                minWidth: imageSize.width,
                maxWidth: imageSize.width,
                minHeight: imageSize.height,
                maxHeight: imageSize.height,
                child: Transform(
                  transform: transform,
                  alignment: Alignment.topLeft,
                  child: SizedBox.fromSize(size: imageSize, child: child),
                ),
              ),
              CustomPaint(painter: _LoupeCrosshairPainter(accent: accent)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Crosshair at the loupe centre so the exact corner position is unambiguous.
class _LoupeCrosshairPainter extends CustomPainter {
  const _LoupeCrosshairPainter({required this.accent});

  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final dark = Paint()
      ..strokeWidth = 3
      ..color = Colors.black.withValues(alpha: 0.35);
    final light = Paint()
      ..strokeWidth = 1
      ..color = accent.withValues(alpha: 0.9);
    const arm = 9.0;

    for (final paint in [dark, light]) {
      canvas.drawLine(
        center - const Offset(arm, 0),
        center + const Offset(arm, 0),
        paint,
      );
      canvas.drawLine(
        center - const Offset(0, arm),
        center + const Offset(0, arm),
        paint,
      );
    }
    canvas.drawCircle(
      center,
      3,
      Paint()..color = accent.withValues(alpha: 0.95),
    );
  }

  @override
  bool shouldRepaint(covariant _LoupeCrosshairPainter oldDelegate) =>
      oldDelegate.accent != accent;
}
