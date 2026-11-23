import 'dart:ui';

/// Non-destructive filters rendered with a [ColorFilter] in the UI and with
/// the `image` package on export.
enum ScanFilter {
  original('Original'),
  grayscale('Grayscale'),
  document('Document');

  const ScanFilter(this.label);
  final String label;
}

/// A single page in a scan batch.
///
/// Edits are stored as instructions (rotation, normalized crop, filter) instead
/// of re-encoding the source image on every change. The pixels are only baked
/// once, at export time, which keeps editing instant and lossless until then.
class ScanPage {
  const ScanPage({
    required this.id,
    required this.imagePath,
    this.quarterTurns = 0,
    this.filter = ScanFilter.original,
    this.crop = const Rect.fromLTWH(0, 0, 1, 1),
  });

  final String id;
  final String imagePath;

  /// Clockwise quarter turns (0-3).
  final int quarterTurns;
  final ScanFilter filter;

  /// Crop rect normalized to the *rotated* page (0..1 on both axes).
  final Rect crop;

  bool get hasCrop =>
      crop.left > 0.001 ||
      crop.top > 0.001 ||
      crop.width < 0.999 ||
      crop.height < 0.999;

  ScanPage copyWith({
    int? quarterTurns,
    ScanFilter? filter,
    Rect? crop,
  }) {
    return ScanPage(
      id: id,
      imagePath: imagePath,
      quarterTurns: quarterTurns ?? this.quarterTurns,
      filter: filter ?? this.filter,
      crop: crop ?? this.crop,
    );
  }

  /// Rotates the page clockwise and rotates the crop rect with it so the
  /// visible region stays the same after the quarter turn.
  ScanPage rotatedClockwise() {
    final turn = (quarterTurns + 1) % 4;
    final rotatedCrop = Rect.fromLTWH(
      1 - crop.top - crop.height,
      crop.left,
      crop.height,
      crop.width,
    );
    return copyWith(quarterTurns: turn, crop: rotatedCrop);
  }

  /// Rotates counter-clockwise (used by the editor's left-rotate action).
  ScanPage rotatedCounterClockwise() {
    final turn = (quarterTurns + 3) % 4;
    final rotatedCrop = Rect.fromLTWH(
      crop.top,
      1 - crop.left - crop.width,
      crop.height,
      crop.width,
    );
    return copyWith(quarterTurns: turn, crop: rotatedCrop);
  }
}
