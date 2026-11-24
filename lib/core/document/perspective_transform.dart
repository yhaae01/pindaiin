import 'dart:typed_data';
import 'dart:ui' show Offset;

/// A 2D projective (perspective) transform stored as a row-major 3×3 matrix.
///
/// The transform maps normalized unit-square coordinates (u, v) in [0, 1] onto
/// a quadrilateral. That is exactly what a document warp needs: every output
/// pixel is turned into a source pixel, so the paper is rectified into a
/// straight rectangle.
class ProjectiveTransform {
  ProjectiveTransform._(this.matrix);

  /// Row-major 3×3 matrix with `matrix[8] == 1`.
  final Float64List matrix;

  /// Builds the transform that maps (0,0)→[quad]`[0]`, (1,0)→`[1]`,
  /// (1,1)→`[2]` and (0,1)→`[3]` (the [DocumentCorners] order).
  factory ProjectiveTransform.unitSquareTo(List<Offset> quad) {
    if (quad.length != 4) {
      throw ArgumentError.value(quad, 'quad', 'Expected exactly 4 corners');
    }

    final a = List<Float64List>.generate(8, (_) => Float64List(8));
    final b = Float64List(8);

    for (var index = 0; index < 4; index++) {
      final u = index == 1 || index == 2 ? 1.0 : 0.0;
      final v = index >= 2 ? 1.0 : 0.0;
      final point = quad[index];
      final row = index * 2;

      a[row]
        ..[0] = u
        ..[1] = v
        ..[2] = 1
        ..[6] = -u * point.dx
        ..[7] = -v * point.dx;
      b[row] = point.dx;

      a[row + 1]
        ..[3] = u
        ..[4] = v
        ..[5] = 1
        ..[6] = -u * point.dy
        ..[7] = -v * point.dy;
      b[row + 1] = point.dy;
    }

    final solved = _solve(a, b);
    return ProjectiveTransform._(Float64List.fromList(<double>[...solved, 1]));
  }

  /// Maps normalized output coordinates to source coordinates.
  Offset transform(double u, double v) {
    final h = matrix;
    final denominator = h[6] * u + h[7] * v + h[8];
    if (denominator.abs() < 1e-12) return Offset.zero;
    return Offset(
      (h[0] * u + h[1] * v + h[2]) / denominator,
      (h[3] * u + h[4] * v + h[5]) / denominator,
    );
  }

  /// Gaussian elimination with partial pivoting.
  static Float64List _solve(List<Float64List> a, Float64List b) {
    const size = 8;
    for (var column = 0; column < size; column++) {
      var pivot = column;
      for (var row = column + 1; row < size; row++) {
        if (a[row][column].abs() > a[pivot][column].abs()) pivot = row;
      }
      if (a[pivot][column].abs() < 1e-12) {
        throw ArgumentError('The corner quad is degenerate.');
      }
      if (pivot != column) {
        final row = a[pivot];
        a[pivot] = a[column];
        a[column] = row;
        final value = b[pivot];
        b[pivot] = b[column];
        b[column] = value;
      }

      final pivotValue = a[column][column];
      for (var row = 0; row < size; row++) {
        if (row == column) continue;
        final factor = a[row][column] / pivotValue;
        if (factor == 0) continue;
        for (var k = column; k < size; k++) {
          a[row][k] -= factor * a[column][k];
        }
        b[row] -= factor * b[column];
      }
    }

    final result = Float64List(size);
    for (var index = 0; index < size; index++) {
      result[index] = b[index] / a[index][index];
    }
    return result;
  }
}
