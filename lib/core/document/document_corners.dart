import 'dart:math' as math;
import 'dart:ui';

/// The four corners of the paper sheet, normalized to the image (0..1).
///
/// Corners are stored in the canonical order **topLeft, topRight,
/// bottomRight, bottomLeft** in the frame the user sees (after any quarter
/// turns). Keeping them normalized means the same quad can be drawn on a small
/// preview and applied to the full-resolution pixels.
class DocumentCorners {
  const DocumentCorners({
    required this.topLeft,
    required this.topRight,
    required this.bottomRight,
    required this.bottomLeft,
  });

  /// The whole photo as the page, e.g. when detection is uncertain.
  static const DocumentCorners fullFrame = DocumentCorners(
    topLeft: Offset(0, 0),
    topRight: Offset(1, 0),
    bottomRight: Offset(1, 1),
    bottomLeft: Offset(0, 1),
  );

  final Offset topLeft;
  final Offset topRight;
  final Offset bottomRight;
  final Offset bottomLeft;

  /// Canonical corner order, useful for painting and warping.
  List<Offset> get points => <Offset>[
    topLeft,
    topRight,
    bottomRight,
    bottomLeft,
  ];

  /// Builds corners from points already in topLeft → bottomLeft order.
  factory DocumentCorners.fromPoints(List<Offset> corners) {
    if (corners.length != 4) {
      throw ArgumentError.value(
        corners,
        'corners',
        'Expected exactly 4 points',
      );
    }
    return DocumentCorners(
      topLeft: corners[0],
      topRight: corners[1],
      bottomRight: corners[2],
      bottomLeft: corners[3],
    );
  }

  /// Sorts four arbitrary points into the canonical corner order.
  ///
  /// Uses the diagonal sums/differences, which is stable for documents rotated
  /// by less than 45°. Returns null when two corners collapse onto the same
  /// extreme (a degenerate or heavily rotated quad).
  static DocumentCorners? order(List<Offset> points) {
    if (points.length != 4) return null;
    var topLeft = points.first;
    var topRight = points.first;
    var bottomRight = points.first;
    var bottomLeft = points.first;

    for (final point in points) {
      if (point.dx + point.dy < topLeft.dx + topLeft.dy) topLeft = point;
      if (point.dx - point.dy > topRight.dx - topRight.dy) topRight = point;
      if (point.dx + point.dy > bottomRight.dx + bottomRight.dy) {
        bottomRight = point;
      }
      if (point.dy - point.dx > bottomLeft.dy - bottomLeft.dx) {
        bottomLeft = point;
      }
    }

    final distinct = <Offset>{topLeft, topRight, bottomRight, bottomLeft};
    if (distinct.length != 4) return null;
    return DocumentCorners(
      topLeft: topLeft,
      topRight: topRight,
      bottomRight: bottomRight,
      bottomLeft: bottomLeft,
    );
  }

  /// Replaces one corner (index follows [points]).
  DocumentCorners withPoint(int index, Offset point) {
    return switch (index % 4) {
      0 => DocumentCorners(
        topLeft: point,
        topRight: topRight,
        bottomRight: bottomRight,
        bottomLeft: bottomLeft,
      ),
      1 => DocumentCorners(
        topLeft: topLeft,
        topRight: point,
        bottomRight: bottomRight,
        bottomLeft: bottomLeft,
      ),
      2 => DocumentCorners(
        topLeft: topLeft,
        topRight: topRight,
        bottomRight: point,
        bottomLeft: bottomLeft,
      ),
      _ => DocumentCorners(
        topLeft: topLeft,
        topRight: topRight,
        bottomRight: bottomRight,
        bottomLeft: point,
      ),
    };
  }

  /// Keeps every corner inside the image, so a dragged handle can never leave
  /// the visible preview.
  DocumentCorners clampedToFrame() {
    Offset clamp(Offset point) =>
        Offset(point.dx.clamp(0.0, 1.0), point.dy.clamp(0.0, 1.0));
    return DocumentCorners(
      topLeft: clamp(topLeft),
      topRight: clamp(topRight),
      bottomRight: clamp(bottomRight),
      bottomLeft: clamp(bottomLeft),
    );
  }

  /// Converts normalized corners to pixel coordinates for [size].
  ///
  /// The normalized values are relative to the image *as displayed*, i.e.
  /// after [rotated] has applied the page's quarter turns. Two useful target
  /// spaces therefore share the same numbers:
  ///
  /// * the on-screen preview widget: its logical size times the normalized
  ///   corner gives the pixel position of the handle inside that widget
  ///   (`x = nx * widgetWidth`, `y = ny * widgetHeight`), and
  /// * the full-resolution photo: the size of the *rotated* source image times
  ///   the same normalized corner gives the source pixel that the warp samples
  ///   (`x = nx * rotatedWidth`, `y = ny * rotatedHeight`).
  ///
  /// That equivalence is what lets a handle dragged on a 320 px preview map to
  /// the exact corner on a 4000 px photo without any additional scaling.
  DocumentCorners scaledTo(Size size) {
    Offset scale(Offset point) =>
        Offset(point.dx * size.width, point.dy * size.height);
    return DocumentCorners(
      topLeft: scale(topLeft),
      topRight: scale(topRight),
      bottomRight: scale(bottomRight),
      bottomLeft: scale(bottomLeft),
    );
  }

  /// Rotates the quad clockwise by [quarterTurns] to match a page rotation.
  ///
  /// In a 90° clockwise turn a normalized point (x, y) becomes (1 - y, x).
  DocumentCorners rotated(int quarterTurns) {
    var result = this;
    for (var turn = 0; turn < quarterTurns % 4; turn++) {
      result = result.rotatedClockwise();
    }
    return result;
  }

  DocumentCorners rotatedClockwise() {
    Offset rotate(Offset point) => Offset(1 - point.dy, point.dx);
    return DocumentCorners(
      topLeft: rotate(bottomLeft),
      topRight: rotate(topLeft),
      bottomRight: rotate(topRight),
      bottomLeft: rotate(bottomRight),
    );
  }

  /// Shoelace area, normalized: 1.0 means the full frame.
  double get area {
    final p = points;
    var sum = 0.0;
    for (var index = 0; index < p.length; index++) {
      final current = p[index];
      final next = p[(index + 1) % p.length];
      sum += current.dx * next.dy - next.dx * current.dy;
    }
    return sum.abs() / 2;
  }

  /// Bounding box of the quad, normalized.
  Rect get bounds {
    final xs = points.map((point) => point.dx);
    final ys = points.map((point) => point.dy);
    return Rect.fromLTRB(
      xs.reduce(math.min),
      ys.reduce(math.min),
      xs.reduce(math.max),
      ys.reduce(math.max),
    );
  }

  /// True when two opposite edges cross, i.e. the quad is a self-intersecting
  /// "bow-tie". Such a quad cannot be warped and is rejected while dragging.
  bool get hasSelfIntersection =>
      _segmentsCross(topLeft, topRight, bottomRight, bottomLeft) ||
      _segmentsCross(topRight, bottomRight, bottomLeft, topLeft);

  static bool _segmentsCross(Offset a, Offset b, Offset c, Offset d) {
    double side(Offset from, Offset to, Offset point) =>
        (to.dx - from.dx) * (point.dy - from.dy) -
        (to.dy - from.dy) * (point.dx - from.dx);

    final d1 = side(a, b, c);
    final d2 = side(a, b, d);
    final d3 = side(c, d, a);
    final d4 = side(c, d, b);
    return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
        ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0));
  }

  /// True when the quad is convex and wound consistently.
  bool get isConvex {
    final p = points;
    var sign = 0;
    for (var index = 0; index < 4; index++) {
      final a = p[index];
      final b = p[(index + 1) % 4];
      final c = p[(index + 2) % 4];
      final cross =
          (b.dx - a.dx) * (c.dy - b.dy) - (b.dy - a.dy) * (c.dx - b.dx);
      if (cross.abs() < 1e-9) continue;
      final current = cross > 0 ? 1 : -1;
      if (sign == 0) {
        sign = current;
      } else if (sign != current) {
        return false;
      }
    }
    return sign != 0;
  }

  /// Shortest edge, normalized by the image diagonal.
  double get shortestEdgeRatio {
    var shortest = double.infinity;
    for (var index = 0; index < 4; index++) {
      final length = (points[(index + 1) % 4] - points[index]).distance;
      if (length < shortest) shortest = length;
    }
    return shortest;
  }

  /// A quad that can be safely warped: convex, non-degenerate, not crossed and
  /// not a sliver.
  bool get isValid =>
      area >= 0.02 &&
      !hasSelfIntersection &&
      isConvex &&
      shortestEdgeRatio >= 0.03;

  /// Moves one corner to [target], clamped to the image bounds.
  ///
  /// Returns null when the clamped result would be degenerate or cross itself,
  /// so a drag can never produce an unwarpable outline. Callers keep the last
  /// accepted corners while the pointer keeps moving.
  DocumentCorners? movedCorner(int index, Offset target) {
    final candidate = withPoint(index, target).clampedToFrame();
    if (candidate.hasSelfIntersection || !candidate.isValid) return null;
    return candidate;
  }

  /// Compares corners within [tolerance] (normalized units).
  bool isCloseTo(DocumentCorners other, {double tolerance = 0.005}) {
    for (var index = 0; index < 4; index++) {
      if ((points[index] - other.points[index]).distance > tolerance) {
        return false;
      }
    }
    return true;
  }

  bool get isFullFrame => isCloseTo(fullFrame, tolerance: 0.01);

  @override
  String toString() =>
      'DocumentCorners(TL:$topLeft, TR:$topRight, BR:$bottomRight, BL:$bottomLeft)';

  @override
  bool operator ==(Object other) =>
      other is DocumentCorners &&
      other.topLeft == topLeft &&
      other.topRight == topRight &&
      other.bottomRight == bottomRight &&
      other.bottomLeft == bottomLeft;

  @override
  int get hashCode => Object.hash(topLeft, topRight, bottomRight, bottomLeft);
}
