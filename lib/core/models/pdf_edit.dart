import 'dart:ui';

/// A markup element placed on a PDF page.
///
/// Coordinates are normalized (0..1) against the page **as currently shown**
/// in the editor, including the page's original rotation and any pending
/// rotation. The service converts them back to unrotated PDF points when it
/// writes the output.
enum PdfMarkKind { text, highlight, ink, image }

class PdfMark {
  const PdfMark({
    required this.id,
    required this.pageId,
    required this.kind,
    required this.rect,
    this.text,
    this.colorValue = 0xFF000000,
    this.points = const [],
    this.imagePath,
    this.opacity = 1,
    this.fontSize = 14,
  });

  final String id;

  /// [PdfPageRef.id] of the page this mark belongs to. Stable across reorder
  /// and rotation, unlike a page index.
  final String pageId;

  final PdfMarkKind kind;

  /// Bounding box in normalized display coordinates.
  final Rect rect;

  /// Text content for [PdfMarkKind.text].
  final String? text;

  /// ARGB color used by text, highlight and ink marks.
  final int colorValue;

  /// Normalized points for [PdfMarkKind.ink].
  final List<Offset> points;

  /// Image path for [PdfMarkKind.image].
  final String? imagePath;

  final double opacity;

  /// Font size in normalized page-height units (0..1). Multiplied by the page
  /// height when the mark is written to the PDF.
  final double fontSize;

  PdfMark copyWith({
    Rect? rect,
    String? text,
    int? colorValue,
    List<Offset>? points,
    double? opacity,
    double? fontSize,
  }) {
    return PdfMark(
      id: id,
      pageId: pageId,
      kind: kind,
      rect: rect ?? this.rect,
      text: text ?? this.text,
      colorValue: colorValue ?? this.colorValue,
      points: points ?? this.points,
      imagePath: imagePath,
      opacity: opacity ?? this.opacity,
      fontSize: fontSize ?? this.fontSize,
    );
  }
}

/// A text run the user chose to replace on a page.
///
/// [bounds] are unrotated PDF points, exactly as returned by the engine's text
/// search, so they can be redacted and re-stamped without screen-coordinate
/// guessing.
class PdfTextReplacement {
  const PdfTextReplacement({
    required this.pageId,
    required this.sourcePage,
    required this.original,
    required this.replacement,
    required this.left,
    required this.bottom,
    required this.right,
    required this.top,
  });

  final String pageId;

  /// Zero-based page index in the **source** document.
  final int sourcePage;
  final String original;
  final String replacement;
  final double left;
  final double bottom;
  final double right;
  final double top;

  double get width => right - left;
  double get height => top - bottom;
}

/// One page in the editor. Page order and rotation are pending edits; the
/// source bytes are untouched until save.
class PdfPageRef {
  const PdfPageRef({
    required this.id,
    required this.sourcePage,
    required this.width,
    required this.height,
    required this.initialQuarterTurns,
    this.rotationDelta = 0,
  });

  final String id;

  /// Zero-based page index in the opened source document.
  final int sourcePage;

  /// Media-box size in PDF points, before rotation.
  final double width;
  final double height;

  /// `/Rotate` already present in the source (0..3 quarter turns clockwise).
  final int initialQuarterTurns;

  /// Rotation added in the editor (0..3 quarter turns clockwise).
  final int rotationDelta;

  int get totalQuarterTurns =>
      (initialQuarterTurns + rotationDelta) % 4;

  /// Size as displayed after original + pending rotation.
  double get displayWidth => totalQuarterTurns.isOdd ? height : width;
  double get displayHeight => totalQuarterTurns.isOdd ? width : height;

  PdfPageRef copyWith({int? rotationDelta}) {
    return PdfPageRef(
      id: id,
      sourcePage: sourcePage,
      width: width,
      height: height,
      initialQuarterTurns: initialQuarterTurns,
      rotationDelta: rotationDelta ?? this.rotationDelta,
    );
  }
}
