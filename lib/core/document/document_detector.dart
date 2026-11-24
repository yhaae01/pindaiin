import 'dart:typed_data';

import 'document_corners.dart';

/// Result of looking for the paper sheet in a photo.
class DocumentDetection {
  const DocumentDetection({
    required this.corners,
    required this.confidence,
    this.note,
  });

  /// Nothing found; the UI starts from the full frame and asks the user.
  const DocumentDetection.unsure({this.note})
    : corners = DocumentCorners.fullFrame,
      confidence = 0;

  /// Corners in the *source image* orientation (apply the page quarter turns
  /// with [rotated] before drawing).
  final DocumentCorners corners;

  /// 0..1. Below ~0.55 the automatic quad is worth showing, but the user
  /// should verify it.
  final double confidence;

  /// Human readable hint for the UI, e.g. why detection fell back.
  final String? note;

  bool get isConfident => confidence >= 0.55;

  DocumentDetection rotated(int quarterTurns) {
    if (quarterTurns % 4 == 0) return this;
    return DocumentDetection(
      corners: corners.rotated(quarterTurns),
      confidence: confidence,
      note: note,
    );
  }
}

/// Finds the paper boundary in a photo.
///
/// Implementations are pure and must be safe to run in a background isolate.
/// Swap the detector returned by `AppServices` to change the algorithm without
/// touching controllers or widgets.
abstract interface class DocumentDetector {
  Future<DocumentDetection> detect(Uint8List imageBytes);
}

/// Detector that does nothing, leaving the full frame as the page. Handy for
/// tests or builds that should skip edge detection entirely.
class FullFrameDocumentDetector implements DocumentDetector {
  const FullFrameDocumentDetector();

  @override
  Future<DocumentDetection> detect(Uint8List imageBytes) async =>
      const DocumentDetection.unsure(note: 'Edge detection is disabled.');
}
