import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/services.dart' show DeviceOrientation;
import 'package:flutter_test/flutter_test.dart';
import 'package:pindaiin/core/document/document_corners.dart';
import 'package:pindaiin/core/document/document_detector.dart';
import 'package:pindaiin/core/document/edge_document_detector.dart';
import 'package:pindaiin/core/document/live_scan.dart';
import 'package:pindaiin/core/document/preview_mapping.dart';

void main() {
  const page = DocumentCorners(
    topLeft: Offset(0.2, 0.15),
    topRight: Offset(0.85, 0.12),
    bottomRight: Offset(0.9, 0.88),
    bottomLeft: Offset(0.15, 0.9),
  );

  DocumentDetection confident([DocumentCorners corners = page]) =>
      DocumentDetection(corners: corners, confidence: 0.9);

  group('PreviewViewportMapping', () {
    test('rotates the sensor frame to portrait and crops with BoxFit.cover', () {
      const mapping = PreviewViewportMapping(
        frameSize: Size(1280, 720),
        quarterTurns: 1,
        viewport: Size(400, 800),
      );

      expect(mapping.naturalSize, const Size(720, 1280));
      // 720x1280 scaled to cover 400x800 -> 450x800, centered horizontally.
      expect(mapping.displayRect, const Rect.fromLTWH(-25, 0, 450, 800));
      expect(mapping.map(const Offset(0, 0)), const Offset(-25, 0));
      expect(mapping.map(const Offset(1, 1)), const Offset(425, 800));
      // The center is unaffected by cover cropping.
      expect(mapping.map(const Offset(0.5, 0.5)), const Offset(200, 400));
    });

    test('an exact aspect match maps corners linearly', () {
      const mapping = PreviewViewportMapping(
        frameSize: Size(1280, 720),
        quarterTurns: 0,
        viewport: Size(800, 450),
      );

      expect(mapping.displayRect, const Rect.fromLTWH(0, 0, 800, 450));
      expect(mapping.map(const Offset(0.25, 0.5)), const Offset(200, 225));
    });

    test('maps all four corners in order', () {
      const mapping = PreviewViewportMapping(
        frameSize: Size(100, 200),
        quarterTurns: 0,
        viewport: Size(100, 200),
      );
      final points = mapping.mapCorners(page);

      expect(points, hasLength(4));
      expect(points[0], const Offset(20, 30));
      expect(points[2], const Offset(90, 176));
    });

    test('empty sizes fall back to the viewport instead of dividing by zero', () {
      const mapping = PreviewViewportMapping(
        frameSize: Size.zero,
        quarterTurns: 0,
        viewport: Size(100, 100),
      );
      expect(mapping.displayRect, const Rect.fromLTWH(0, 0, 100, 100));
    });
  });

  group('previewQuarterTurns', () {
    test('portrait phone needs a 90 degree turn of the sensor frame', () {
      expect(
        previewQuarterTurns(
          sensorOrientation: 90,
          deviceOrientation: DeviceOrientation.portraitUp,
        ),
        1,
      );
    });

    test('each device rotation is compensated', () {
      int turns(DeviceOrientation orientation) => previewQuarterTurns(
        sensorOrientation: 90,
        deviceOrientation: orientation,
      );

      expect(turns(DeviceOrientation.landscapeLeft), 0);
      expect(turns(DeviceOrientation.portraitDown), 3);
      expect(turns(DeviceOrientation.landscapeRight), 2);
    });
  });

  group('LiveScanTracker', () {
    const config = LiveScanConfig(
      stableFrames: 3,
      stableTolerance: 0.02,
      smoothing: 0,
      holdMissedFrames: 2,
    );

    test('becomes stable only after consecutive consistent frames', () {
      final tracker = LiveScanTracker(config: config);

      final first = tracker.update(confident(), quarterTurns: 0);
      final second = tracker.update(confident(), quarterTurns: 0);
      final third = tracker.update(confident(), quarterTurns: 0);
      final fourth = tracker.update(confident(), quarterTurns: 0);

      // The first frame sets the baseline; three consistent frames follow.
      expect(first.stable, isFalse);
      expect(second.stable, isFalse);
      expect(third.stable, isFalse);
      expect(fourth.stable, isTrue);
      expect(fourth.stability, 1);
      expect(fourth.corners, page);
    });

    test('rotates detected corners into the displayed orientation', () {
      final tracker = LiveScanTracker(config: config);
      final update = tracker.update(confident(), quarterTurns: 1);

      expect(update.corners, page.rotated(1));
    });

    test('a moved page resets the stability streak', () {
      final tracker = LiveScanTracker(config: config);
      tracker.update(confident(), quarterTurns: 0);
      tracker.update(confident(), quarterTurns: 0);

      const moved = DocumentCorners(
        topLeft: Offset(0.3, 0.15),
        topRight: Offset(0.9, 0.12),
        bottomRight: Offset(0.95, 0.88),
        bottomLeft: Offset(0.25, 0.9),
      );
      final afterMove = tracker.update(confident(moved), quarterTurns: 0);

      expect(afterMove.stable, isFalse);
      expect(afterMove.stability, 0);
    });

    test('smoothing averages out corner jitter', () {
      const smoothConfig = LiveScanConfig(
        smoothing: 0.5,
        stableFrames: 4,
      );
      final tracker = LiveScanTracker(config: smoothConfig);
      tracker.update(confident(), quarterTurns: 0);

      const jittered = DocumentCorners(
        topLeft: Offset(0.24, 0.15),
        topRight: Offset(0.85, 0.12),
        bottomRight: Offset(0.9, 0.88),
        bottomLeft: Offset(0.15, 0.9),
      );
      final update = tracker.update(confident(jittered), quarterTurns: 0);
      final dx = update.corners!.topLeft.dx;

      expect(dx, greaterThan(page.topLeft.dx));
      expect(dx, lessThan(jittered.topLeft.dx));
    });

    test('loses the quad only after the hold frames expired', () {
      final tracker = LiveScanTracker(config: config);
      tracker.update(confident(), quarterTurns: 0);

      const missed = DocumentDetection.unsure(note: 'Dark frame');
      final firstMiss = tracker.update(missed, quarterTurns: 0);
      final secondMiss = tracker.update(missed, quarterTurns: 0);
      final thirdMiss = tracker.update(missed, quarterTurns: 0);

      expect(firstMiss.corners, isNotNull);
      expect(secondMiss.corners, isNotNull);
      expect(thirdMiss.corners, isNull);
      expect(thirdMiss.stable, isFalse);
    });

    test('reset requires a fresh stable streak', () {
      final tracker = LiveScanTracker(config: config);
      tracker.update(confident(), quarterTurns: 0);
      tracker.update(confident(), quarterTurns: 0);
      tracker.update(confident(), quarterTurns: 0);
      expect(tracker.update(confident(), quarterTurns: 0).stable, isTrue);

      tracker.reset();
      final afterReset = tracker.update(confident(), quarterTurns: 0);

      expect(afterReset.stable, isFalse);
      expect(afterReset.stability, 0);
    });

    test('ignores a quad that is too small to be a page', () {
      const trackerConfig = LiveScanConfig(minimumArea: 0.3);
      final tracker = LiveScanTracker(config: trackerConfig);
      const tiny = DocumentCorners(
        topLeft: Offset(0.1, 0.1),
        topRight: Offset(0.25, 0.1),
        bottomRight: Offset(0.25, 0.2),
        bottomLeft: Offset(0.1, 0.2),
      );
      final update = tracker.update(confident(tiny), quarterTurns: 0);

      // The synthetic page covers well under 30% of the frame.
      expect(update.corners, isNull);
      expect(update.confidence, 0.9);
    });
  });

  group('detectDocumentLuminance', () {
    Uint8List sheetFrame(int width, int height) {
      final frame = Uint8List(width * height)..fillRange(0, width * height, 32);
      for (var y = 12; y < height - 12; y++) {
        for (var x = 20; x < width - 20; x++) {
          frame[y * width + x] = 242;
        }
      }
      return frame;
    }

    test('finds the bright sheet directly from raw luminance', () {
      const width = 200;
      const height = 120;
      final detection = detectDocumentLuminance(
        sheetFrame(width, height),
        width: width,
        height: height,
      );

      expect(detection.confidence, greaterThanOrEqualTo(0.55));
      expect(detection.corners.isValid, isTrue);
      expect(detection.corners.topLeft.dx, closeTo(0.1, 0.04));
      expect(detection.corners.topLeft.dy, closeTo(0.1, 0.04));
      expect(detection.corners.bottomRight.dx, closeTo(0.9, 0.04));
      expect(detection.corners.bottomRight.dy, closeTo(0.9, 0.04));
    });

    test('downsamples frames larger than the analysis size', () {
      const width = 800;
      const height = 480;
      final detection = detectDocumentLuminance(
        sheetFrame(width, height),
        width: width,
        height: height,
        analysisSize: 240,
      );

      expect(detection.confidence, greaterThanOrEqualTo(0.55));
      expect(detection.corners.isValid, isTrue);
    });

    test('rejects an empty or malformed frame', () {
      final detection = detectDocumentLuminance(
        Uint8List(10),
        width: 100,
        height: 100,
      );

      expect(detection.corners.isFullFrame, isTrue);
      expect(detection.confidence, 0);
    });
  });
}
