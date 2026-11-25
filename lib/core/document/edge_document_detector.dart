import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:image/image.dart' as img;

import 'document_corners.dart';
import 'document_detector.dart';

/// Finds the brightest large region (the paper) and fits a quadrilateral to its
/// outline.
///
/// The photo is analysed at [analysisSize] px: cheap, noise tolerant, and it
/// makes the detector independent of the camera resolution. It is a
/// transparency-based detector, which covers the common "sheet of paper on a
/// darker surface" case; when it is not sure it returns a low confidence quad
/// so the UI can ask the user to drag the corners.
class EdgeDocumentDetector implements DocumentDetector {
  const EdgeDocumentDetector({
    this.analysisSize = 480,
    this.minimumConfidence = 0.55,
  });

  /// Longest edge of the analysis copy.
  final int analysisSize;

  /// Confidence under which the result is treated as a guess.
  final double minimumConfidence;

  @override
  Future<DocumentDetection> detect(Uint8List imageBytes) {
    final size = analysisSize;
    return Isolate.run(
      () => detectDocumentEdges(imageBytes, analysisSize: size),
    );
  }
}

/// Synchronous detector used inside an isolate and by tests.
DocumentDetection detectDocumentEdges(
  Uint8List imageBytes, {
  int analysisSize = 480,
}) {
  final decoded = img.decodeImage(imageBytes);
  if (decoded == null) {
    return const DocumentDetection.unsure(note: 'The image could not be read.');
  }

  img.Image image;
  try {
    image = img.bakeOrientation(decoded);
  } catch (_) {
    image = decoded;
  }

  final longest = math.max(image.width, image.height);
  if (longest > analysisSize) {
    final scale = analysisSize / longest;
    image = img.copyResize(
      image,
      width: math.max(1, (image.width * scale).round()),
      height: math.max(1, (image.height * scale).round()),
      interpolation: img.Interpolation.average,
    );
  }

  return detectDocumentLuminance(
    _luminanceOf(image),
    width: image.width,
    height: image.height,
    analysisSize: analysisSize,
  );
}

/// Detects the page on a grayscale (luminance) frame.
///
/// This is the detector core shared by still photos and live camera preview
/// frames. [luminance] must contain [width] × [height] bytes, row-major. Frames
/// longer than [analysisSize] are resampled down first, so the work per frame
/// stays bounded regardless of the camera resolution.
DocumentDetection detectDocumentLuminance(
  Uint8List luminance, {
  required int width,
  required int height,
  int analysisSize = 480,
  int hullPoints = 48,
}) {
  if (width <= 0 || height <= 0 || luminance.length < width * height) {
    return const DocumentDetection.unsure(
      note: 'The camera frame could not be read.',
    );
  }

  final longest = math.max(width, height);
  if (longest > analysisSize) {
    final scale = analysisSize / longest;
    final targetWidth = math.max(1, (width * scale).round());
    final targetHeight = math.max(1, (height * scale).round());
    return _detectFromLuminance(
      _resample(luminance, width, height, targetWidth, targetHeight),
      targetWidth,
      targetHeight,
      hullPoints,
    );
  }
  return _detectFromLuminance(luminance, width, height, hullPoints);
}

Uint8List _luminanceOf(img.Image image) {
  final width = image.width;
  final height = image.height;
  final luminance = Uint8List(width * height);
  for (var y = 0; y < height; y++) {
    final row = y * width;
    for (var x = 0; x < width; x++) {
      final pixel = image.getPixel(x, y);
      final value = (0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b).clamp(
        0,
        255,
      );
      luminance[row + x] = value.toInt();
    }
  }
  return luminance;
}

/// Nearest-neighbour grayscale resample. Detection tolerates the aliasing and
/// it is much cheaper than a filtered resize per camera frame.
Uint8List _resample(
  Uint8List source,
  int sourceWidth,
  int sourceHeight,
  int targetWidth,
  int targetHeight,
) {
  final output = Uint8List(targetWidth * targetHeight);
  for (var y = 0; y < targetHeight; y++) {
    final sourceY = math.min(
      sourceHeight - 1,
      (y * sourceHeight / targetHeight).floor(),
    );
    final sourceRow = sourceY * sourceWidth;
    final targetRow = y * targetWidth;
    for (var x = 0; x < targetWidth; x++) {
      final sourceX = math.min(
        sourceWidth - 1,
        (x * sourceWidth / targetWidth).floor(),
      );
      output[targetRow + x] = source[sourceRow + sourceX];
    }
  }
  return output;
}

DocumentDetection _detectFromLuminance(
  Uint8List luminance,
  int width,
  int height,
  int hullPoints,
) {
  final pixelCount = width * height;
  if (pixelCount < 64) {
    return const DocumentDetection.unsure(note: 'The image is too small.');
  }

  // 1. A global threshold (Otsu) that separates the bright sheet from the
  //    darker surroundings.
  final threshold = _otsuThreshold(luminance);
  final bright = Uint8List(pixelCount);
  var brightCount = 0;
  for (var index = 0; index < pixelCount; index++) {
    if (luminance[index] >= threshold) {
      bright[index] = 1;
      brightCount++;
    }
  }

  final brightRatio = brightCount / pixelCount;
  if (brightRatio < 0.08) {
    return const DocumentDetection.unsure(
      note: 'No bright region stood out from the background.',
    );
  }
  if (brightRatio > 0.985) {
    return DocumentDetection(
      corners: DocumentCorners.fullFrame,
      confidence: 0.7,
      note: 'The page fills the frame.',
    );
  }

  // 2. Largest connected bright region. Everything else (hands, table, other
  //    bright objects) is ignored.
  final component = _largestComponent(bright, width, height);
  if (component == null) {
    return const DocumentDetection.unsure(note: 'No page-like region found.');
  }

  final coverage = component.size / pixelCount;
  if (coverage < 0.1) {
    return const DocumentDetection.unsure(
      note: 'The bright region is too small to be a page.',
    );
  }
  if (coverage > 0.96) {
    return DocumentDetection(
      corners: DocumentCorners.fullFrame,
      confidence: 0.7,
      note: 'The page fills the frame.',
    );
  }

  // 3. Fit a quad to the outline: convex hull, then the largest inscribed
  //    quadrilateral. Hull sampling keeps the fit O(n^3) on a small n.
  final hull = _convexHull(component.boundary);
  if (hull.length < 4) {
    return const DocumentDetection.unsure(
      note: 'The page outline is too irregular to detect.',
    );
  }
  final sampled = _sample(hull, hullPoints.clamp(8, 64));
  final indices = _largestQuadrilateral(sampled);
  if (indices.isEmpty) {
    return const DocumentDetection.unsure(note: 'No four-sided outline found.');
  }

  final normalized = indices
      .map(
        (index) =>
            Offset(sampled[index].dx / width, sampled[index].dy / height),
      )
      .toList(growable: false);

  final corners = DocumentCorners.order(normalized);
  if (corners == null || !corners.isValid) {
    return const DocumentDetection.unsure(
      note: 'The detected outline is not a valid page.',
    );
  }
  if (corners.area > 0.95) {
    return DocumentDetection(
      corners: DocumentCorners.fullFrame,
      confidence: 0.7,
      note: 'The page fills the frame.',
    );
  }

  // 4. Confidence: how well the bright region fills the quad, plus how
  //    page-sized the quad is.
  final fill = (component.size / (corners.area * pixelCount)).clamp(0.0, 1.0);
  final plausibleSize = corners.area >= 0.15 && corners.area <= 0.92
      ? 1.0
      : 0.5;
  final confidence = (0.35 + 0.45 * fill + 0.2 * plausibleSize).clamp(0.0, 1.0);

  return DocumentDetection(
    corners: corners,
    confidence: confidence,
    note: confidence < 0.55
        ? 'Edges are unclear. Drag the corners to fit the page.'
        : null,
  );
}

class _Component {
  const _Component({required this.size, required this.boundary});

  final int size;
  final List<Offset> boundary;
}

/// Breadth-first flood fill returning the biggest bright blob and its outline
/// pixels (pixels that have at least one background neighbour).
_Component? _largestComponent(Uint8List mask, int width, int height) {
  final visited = Uint8List(mask.length);
  final queue = Int32List(mask.length);
  final heightIndex = height;

  var bestSize = 0;
  List<Offset>? bestBoundary;

  for (var seed = 0; seed < mask.length; seed++) {
    if (mask[seed] == 0 || visited[seed] == 1) continue;

    var head = 0;
    var tail = 0;
    queue[tail++] = seed;
    visited[seed] = 1;
    var size = 0;
    final boundary = <Offset>[];

    while (head < tail) {
      final index = queue[head++];
      size++;
      final x = index % width;
      final y = index ~/ width;

      var isEdge = x == 0 || y == 0 || x == width - 1 || y == height - 1;
      final left = x > 0 ? index - 1 : -1;
      final right = x < width - 1 ? index + 1 : -1;
      final up = y > 0 ? index - width : -1;
      final down = y < height - 1 ? index + width : -1;
      for (final neighbour in [left, right, up, down]) {
        if (neighbour < 0) continue;
        if (mask[neighbour] == 0) {
          isEdge = true;
        } else if (visited[neighbour] == 0) {
          visited[neighbour] = 1;
          if (tail < queue.length) queue[tail++] = neighbour;
        }
      }
      if (isEdge && boundary.length < 40000) {
        boundary.add(Offset(x.toDouble(), y.toDouble()));
      }
    }

    if (size > bestSize) {
      bestSize = size;
      bestBoundary = boundary;
    }
    if (bestSize > (width * heightIndex) * 0.995) break;
  }

  if (bestBoundary == null) return null;
  return _Component(size: bestSize, boundary: bestBoundary);
}

/// Andrew's monotone chain, counter-clockwise.
List<Offset> _convexHull(List<Offset> points) {
  if (points.length < 3) return List<Offset>.of(points);
  final sorted = List<Offset>.of(
    points,
  )..sort((a, b) => a.dx == b.dx ? a.dy.compareTo(b.dy) : a.dx.compareTo(b.dx));

  double cross(Offset origin, Offset a, Offset b) =>
      (a.dx - origin.dx) * (b.dy - origin.dy) -
      (a.dy - origin.dy) * (b.dx - origin.dx);

  final lower = <Offset>[];
  for (final point in sorted) {
    while (lower.length >= 2 &&
        cross(lower[lower.length - 2], lower.last, point) <= 0) {
      lower.removeLast();
    }
    lower.add(point);
  }

  final upper = <Offset>[];
  for (final point in sorted.reversed) {
    while (upper.length >= 2 &&
        cross(upper[upper.length - 2], upper.last, point) <= 0) {
      upper.removeLast();
    }
    upper.add(point);
  }

  lower.removeLast();
  upper.removeLast();
  return <Offset>[...lower, ...upper];
}

/// Evenly samples a convex polygon down to at most [maxPoints] vertices.
List<Offset> _sample(List<Offset> hull, int maxPoints) {
  if (hull.length <= maxPoints) return hull;
  final stride = (hull.length / maxPoints).ceil();
  final sampled = <Offset>[];
  for (var index = 0; index < hull.length; index += stride) {
    sampled.add(hull[index]);
  }
  return sampled;
}

double _triangleArea(Offset a, Offset b, Offset c) =>
    ((b.dx - a.dx) * (c.dy - a.dy) - (b.dy - a.dy) * (c.dx - a.dx)).abs() / 2;

/// Largest-area quadrilateral inscribed in a convex polygon (O(n^3) on the
/// sampled hull), returned as cyclic vertex indices.
List<int> _largestQuadrilateral(List<Offset> hull) {
  final count = hull.length;
  if (count < 4) return const [];

  var bestArea = 0.0;
  List<int> best = const [];

  for (var i = 0; i < count; i++) {
    for (var j = i + 2; j < count; j++) {
      if (i == 0 && j == count - 1) continue;

      var kBest = -1;
      var kArea = 0.0;
      for (var k = i + 1; k < j; k++) {
        final area = _triangleArea(hull[i], hull[j], hull[k]);
        if (area > kArea) {
          kArea = area;
          kBest = k;
        }
      }

      var lBest = -1;
      var lArea = 0.0;
      for (var l = j + 1; l < count; l++) {
        final area = _triangleArea(hull[j], hull[i], hull[l]);
        if (area > lArea) {
          lArea = area;
          lBest = l;
        }
      }
      for (var l = 0; l < i; l++) {
        final area = _triangleArea(hull[j], hull[i], hull[l]);
        if (area > lArea) {
          lArea = area;
          lBest = l;
        }
      }

      final total = kArea + lArea;
      if (kBest >= 0 && lBest >= 0 && total > bestArea) {
        bestArea = total;
        best = <int>[i, kBest, j, lBest];
      }
    }
  }
  return best;
}

/// Otsu's method: the threshold that maximizes between-class variance.
int _otsuThreshold(Uint8List values) {
  final histogram = List<int>.filled(256, 0);
  for (final value in values) {
    histogram[value]++;
  }

  final total = values.length;
  var sum = 0.0;
  for (var index = 0; index < 256; index++) {
    sum += index * histogram[index];
  }

  var sumBackground = 0.0;
  var backgroundWeight = 0;
  var bestVariance = 0.0;
  var threshold = 127;

  for (var level = 0; level < 256; level++) {
    backgroundWeight += histogram[level];
    if (backgroundWeight == 0) continue;
    final foregroundWeight = total - backgroundWeight;
    if (foregroundWeight == 0) break;

    sumBackground += level * histogram[level];
    final meanBackground = sumBackground / backgroundWeight;
    final meanForeground = (sum - sumBackground) / foregroundWeight;
    final variance =
        backgroundWeight *
        foregroundWeight *
        (meanBackground - meanForeground) *
        (meanBackground - meanForeground);

    if (variance > bestVariance) {
      bestVariance = variance;
      threshold = level;
    }
  }

  // A tiny margin helps with slightly off-white paper (and avoids selecting
  // the paper's own shading as "background").
  return (threshold + 6).clamp(1, 255);
}
