import 'dart:ui';

/// Coordinate helpers shared by the PDF editor's preview and save pipeline.
///
/// All points are normalized 0..1. Page rotation is clockwise quarter turns,
/// matching the PDF `/Rotate` entry. "Display" means the page as the user sees
/// it after rotation; "unrotated" means the page's PDF media-box coordinate
/// space with y down.
class PdfGeometry {
  PdfGeometry._();

  /// Maps an unrotated page point to its position on screen after [quarterTurns]
  /// clockwise quarter turns.
  static Offset unrotatedToDisplay(Offset point, int quarterTurns) {
    final x = point.dx;
    final y = point.dy;
    return switch (quarterTurns % 4) {
      1 => Offset(1 - y, x),
      2 => Offset(1 - x, 1 - y),
      3 => Offset(y, 1 - x),
      _ => point,
    };
  }

  /// Inverse of [unrotatedToDisplay].
  static Offset displayToUnrotated(Offset point, int quarterTurns) {
    final x = point.dx;
    final y = point.dy;
    return switch (quarterTurns % 4) {
      1 => Offset(y, 1 - x),
      2 => Offset(1 - x, 1 - y),
      3 => Offset(1 - y, x),
      _ => point,
    };
  }

  /// Bounding box of an unrotated rectangle after rotation. Rotated rectangles
  /// stay axis aligned for quarter turns.
  static Rect rectUnrotatedToDisplay(Rect rect, int quarterTurns) {
    final a = unrotatedToDisplay(rect.topLeft, quarterTurns);
    final b = unrotatedToDisplay(rect.bottomRight, quarterTurns);
    return Rect.fromLTRB(
      a.dx < b.dx ? a.dx : b.dx,
      a.dy < b.dy ? a.dy : b.dy,
      a.dx > b.dx ? a.dx : b.dx,
      a.dy > b.dy ? a.dy : b.dy,
    );
  }

  /// Re-expresses a rectangle from one rotation to another while keeping it
  /// attached to the same page content.
  static Rect rotateRect(Rect rect, int fromQuarterTurns, int toQuarterTurns) {
    final topLeft = displayToUnrotated(rect.topLeft, fromQuarterTurns);
    final bottomRight = displayToUnrotated(rect.bottomRight, fromQuarterTurns);
    return rectUnrotatedToDisplay(
      Rect.fromPoints(topLeft, bottomRight),
      toQuarterTurns,
    );
  }

  /// Rotates normalized ink points from one display orientation to another.
  static List<Offset> rotatePoints(
    List<Offset> points,
    int fromQuarterTurns,
    int toQuarterTurns,
  ) {
    return points
        .map(
          (point) => unrotatedToDisplay(
            displayToUnrotated(point, fromQuarterTurns),
            toQuarterTurns,
          ),
        )
        .toList(growable: false);
  }

  /// Normalized display rectangle to unrotated PDF points (y up).
  static ({double left, double bottom, double right, double top}) toPdfPoints({
    required Rect rect,
    required int quarterTurns,
    required double pageWidth,
    required double pageHeight,
  }) {
    final topLeft = displayToUnrotated(rect.topLeft, quarterTurns);
    final bottomRight = displayToUnrotated(rect.bottomRight, quarterTurns);
    final left = (topLeft.dx < bottomRight.dx ? topLeft.dx : bottomRight.dx) *
        pageWidth;
    final right = (topLeft.dx > bottomRight.dx ? topLeft.dx : bottomRight.dx) *
        pageWidth;
    final topN = (topLeft.dy < bottomRight.dy ? topLeft.dy : bottomRight.dy);
    final bottomN =
        (topLeft.dy > bottomRight.dy ? topLeft.dy : bottomRight.dy);
    return (
      left: left,
      bottom: (1 - bottomN) * pageHeight,
      right: right,
      top: (1 - topN) * pageHeight,
    );
  }
}
