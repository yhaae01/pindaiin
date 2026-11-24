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
    this.sourceImagePath,
    this.quarterTurns = 0,
    this.filter = ScanFilter.original,
    this.crop = const Rect.fromLTWH(0, 0, 1, 1),
  });

  final String id;

  /// The image shown and exported (a warped working copy after edge
  /// adjustment, the imported photo before that).
  final String imagePath;

  /// Untouched, full-frame copy of the captured/imported photo. It is kept so
  /// edge adjustment can restart from the original instead of degrading an
  /// already warped image.
  final String? sourceImagePath;

  /// File to run edge detection on, and to warp from.
  String get editableSourcePath => sourceImagePath ?? imagePath;

  bool get hasPerspectiveWarp => sourceImagePath != null;

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
    String? imagePath,
    String? sourceImagePath,
    int? quarterTurns,
    ScanFilter? filter,
    Rect? crop,
  }) {
    return ScanPage(
      id: id,
      imagePath: imagePath ?? this.imagePath,
      sourceImagePath: sourceImagePath ?? this.sourceImagePath,
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
