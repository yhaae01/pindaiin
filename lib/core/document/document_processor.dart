import 'dart:io';
import 'dart:typed_data';

import '../models/conversion.dart';
import 'document_corners.dart';
import 'document_detector.dart';
import 'edge_document_detector.dart';
import 'perspective_warper.dart';

/// Entry point of the document pipeline: detect the page, warp it straight.
///
/// Both steps are pluggable. Replace [detector] (e.g. an ML based detector) or
/// [warper] (e.g. a native OpenCV binding) in `AppServices` and nothing above
/// this class changes.
class DocumentProcessor {
  DocumentProcessor({DocumentDetector? detector, PerspectiveWarper? warper})
    : detector = detector ?? const EdgeDocumentDetector(),
      warper = warper ?? const HomographyPerspectiveWarper();

  final DocumentDetector detector;
  final PerspectiveWarper warper;

  /// Working copies are capped here; exports still honour their own quality.
  static const int workingMaxDimension = 2600;

  Future<DocumentDetection> detectFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw const ConversionException(
        'The page image is missing. It may have been deleted outside the app.',
      );
    }
    return detector.detect(await file.readAsBytes());
  }

  Future<Uint8List> warpFile(
    String path, {
    required DocumentCorners corners,
    int quarterTurns = 0,
    int maxDimension = workingMaxDimension,
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      throw const ConversionException(
        'The page image is missing. It may have been deleted outside the app.',
      );
    }
    return warpBytes(
      await file.readAsBytes(),
      corners: corners,
      quarterTurns: quarterTurns,
      maxDimension: maxDimension,
    );
  }

  Future<Uint8List> warpBytes(
    Uint8List bytes, {
    required DocumentCorners corners,
    int quarterTurns = 0,
    int maxDimension = workingMaxDimension,
  }) {
    if (!corners.isValid) {
      throw const ConversionException(
        'The page outline is invalid. Adjust the four corners and try again.',
      );
    }
    return warper.warp(
      sourceBytes: bytes,
      corners: corners,
      quarterTurns: quarterTurns,
      maxDimension: maxDimension,
    );
  }
}
