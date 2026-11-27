import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pindaiin/core/document/document_corners.dart';
import 'package:pindaiin/core/document/edge_document_detector.dart';
import 'package:pindaiin/core/document/perspective_transform.dart';
import 'package:pindaiin/core/document/perspective_warper.dart';
import 'package:pindaiin/core/widgets/document_quad_overlay.dart';

void main() {
  group('DocumentCorners', () {
    const skewed = DocumentCorners(
      topLeft: Offset(0.1, 0.2),
      topRight: Offset(0.9, 0.1),
      bottomRight: Offset(0.8, 0.9),
      bottomLeft: Offset(0.2, 0.7),
    );

    test('a full frame quad is valid and covers the image', () {
      expect(DocumentCorners.fullFrame.area, closeTo(1, 1e-9));
      expect(DocumentCorners.fullFrame.isValid, isTrue);
      expect(DocumentCorners.fullFrame.isFullFrame, isTrue);
      expect(skewed.isFullFrame, isFalse);
    });

    test('rotating four times restores the original corners', () {
      final back = skewed.rotated(4);
      expect(back.isCloseTo(skewed), isTrue);
    });

    test('a clockwise turn moves corners with the image', () {
      final rotated = skewed.rotatedClockwise();

      expect(rotated.topLeft.dx, closeTo(1 - skewed.bottomLeft.dy, 1e-9));
      expect(rotated.topLeft.dy, closeTo(skewed.bottomLeft.dx, 1e-9));
      expect(rotated.bottomRight.dx, closeTo(1 - skewed.topRight.dy, 1e-9));
      expect(rotated.bottomRight.dy, closeTo(skewed.topRight.dx, 1e-9));
    });

    test('order() sorts shuffled corners into the canonical order', () {
      final ordered = DocumentCorners.order([
        skewed.bottomRight,
        skewed.topLeft,
        skewed.bottomLeft,
        skewed.topRight,
      ]);

      expect(ordered, isNotNull);
      expect(ordered!.topLeft, skewed.topLeft);
      expect(ordered.topRight, skewed.topRight);
      expect(ordered.bottomRight, skewed.bottomRight);
      expect(ordered.bottomLeft, skewed.bottomLeft);
    });

    test('a crossed quad is rejected', () {
      const crossed = DocumentCorners(
        topLeft: Offset(0.2, 0.1),
        topRight: Offset(0.8, 0.1),
        bottomRight: Offset(0.2, 0.9),
        bottomLeft: Offset(0.8, 0.9),
      );

      expect(crossed.isConvex, isFalse);
      expect(crossed.isValid, isFalse);
    });

    test('self-intersecting quads are reported', () {
      const crossed = DocumentCorners(
        topLeft: Offset(0.2, 0.1),
        topRight: Offset(0.8, 0.1),
        bottomRight: Offset(0.2, 0.9),
        bottomLeft: Offset(0.8, 0.9),
      );

      expect(crossed.hasSelfIntersection, isTrue);
      expect(skewed.hasSelfIntersection, isFalse);
      expect(DocumentCorners.fullFrame.hasSelfIntersection, isFalse);
    });

    test('a corner drag is clamped and cannot cross the outline', () {
      const quad = DocumentCorners(
        topLeft: Offset(0.1, 0.1),
        topRight: Offset(0.9, 0.1),
        bottomRight: Offset(0.9, 0.9),
        bottomLeft: Offset(0.1, 0.9),
      );

      final clamped = quad.movedCorner(0, const Offset(-0.5, -0.4));
      expect(clamped, isNotNull);
      expect(clamped!.topLeft, Offset.zero);
      expect(clamped.isValid, isTrue);

      // Dragging a corner over its neighbours would fold the quad.
      expect(quad.movedCorner(0, const Offset(0.95, 0.95)), isNull);
      expect(quad.movedCorner(0, const Offset(0.9, 0.1)), isNull);
    });

    test('normalized corners map proportionally to preview and full res', () {
      final preview = skewed.scaledTo(const Size(320, 240));
      final full = skewed.scaledTo(const Size(4000, 3000));

      for (var index = 0; index < 4; index++) {
        expect(
          preview.points[index].dx / 320,
          closeTo(full.points[index].dx / 4000, 1e-9),
        );
        expect(
          preview.points[index].dy / 240,
          closeTo(full.points[index].dy / 3000, 1e-9),
        );
      }
    });

    test('dragged corners are clamped to the frame', () {
      const outside = DocumentCorners(
        topLeft: Offset(-0.2, -0.1),
        topRight: Offset(1.3, 0),
        bottomRight: Offset(1, 1.2),
        bottomLeft: Offset(0, 1),
      );

      final clamped = outside.clampedToFrame();
      expect(clamped.topLeft, Offset.zero);
      expect(clamped.topRight.dx, 1);
      expect(clamped.bottomRight.dy, 1);
    });
  });

  group('ProjectiveTransform', () {
    test('maps the unit square onto the four corners', () {
      const quad = <Offset>[
        Offset(10, 20),
        Offset(110, 10),
        Offset(120, 90),
        Offset(5, 100),
      ];
      final transform = ProjectiveTransform.unitSquareTo(quad);

      void expectNear(Offset actual, Offset expected) {
        expect(actual.dx, closeTo(expected.dx, 1e-6));
        expect(actual.dy, closeTo(expected.dy, 1e-6));
      }

      expectNear(transform.transform(0, 0), quad[0]);
      expectNear(transform.transform(1, 0), quad[1]);
      expectNear(transform.transform(1, 1), quad[2]);
      expectNear(transform.transform(0, 1), quad[3]);
    });
  });

  group('Perspective warp', () {
    test('crops to the selected quad and keeps the quad aspect ratio', () {
      // Left half red, right half blue.
      final source = img.Image(width: 200, height: 100);
      img.fill(source, color: img.ColorRgb8(255, 0, 0));
      img.fillRect(
        source,
        x1: 100,
        y1: 0,
        x2: 199,
        y2: 99,
        color: img.ColorRgb8(0, 0, 255),
      );

      final bytes = warpDocumentPerspective(
        img.encodePng(source),
        quad: const <double>[0.5, 0, 1, 0, 1, 1, 0.5, 1],
        maxDimension: 600,
      );

      final warped = img.decodeImage(bytes);
      expect(warped, isNotNull);
      expect(warped!.width, closeTo(100, 2));
      expect(warped.height, closeTo(100, 2));

      final center = warped.getPixel(warped.width ~/ 2, warped.height ~/ 2);
      expect(center.b, greaterThan(180));
      expect(center.r, lessThan(70));
    });

    test('applies quarter turns before mapping the corners', () {
      final source = img.Image(width: 200, height: 100);
      img.fill(source, color: img.ColorRgb8(10, 200, 10));

      final bytes = warpDocumentPerspective(
        img.encodePng(source),
        quad: const <double>[0, 0, 1, 0, 1, 1, 0, 1],
        quarterTurns: 1,
      );

      final warped = img.decodeImage(bytes);
      expect(warped, isNotNull);
      expect(warped!.width, closeTo(100, 2));
      expect(warped.height, closeTo(200, 2));
    });

    test('rejects a degenerate quad', () {
      final source = img.Image(width: 40, height: 40);
      img.fill(source, color: img.ColorRgb8(255, 255, 255));

      expect(
        () => warpDocumentPerspective(
          img.encodePng(source),
          quad: const <double>[0, 0, 0, 0, 0, 0, 0, 0],
        ),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('DocumentQuadOverlay', () {
    testWidgets('a generous touch target drags and clamps the corner', (
      tester,
    ) async {
      var corners = const DocumentCorners(
        topLeft: Offset(0.2, 0.2),
        topRight: Offset(0.8, 0.2),
        bottomRight: Offset(0.8, 0.8),
        bottomLeft: Offset(0.2, 0.8),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 200,
              height: 200,
              child: StatefulBuilder(
                builder: (context, setState) => DocumentQuadOverlay(
                  corners: corners,
                  onChanged: (value) => setState(() => corners = value),
                ),
              ),
            ),
          ),
        ),
      );

      final origin = tester.getTopLeft(find.byType(DocumentQuadOverlay));
      // Grab 30 px away from the handle; still inside the touch target.
      final gesture = await tester.startGesture(
        origin + const Offset(40 + 30, 40 + 30),
      );
      await tester.pump();
      await gesture.moveBy(const Offset(-200, -200));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(corners.topLeft, Offset.zero);
      expect(corners.isValid, isTrue);
    });

    testWidgets('dragging a corner across the quad is ignored', (tester) async {
      var corners = const DocumentCorners(
        topLeft: Offset(0.2, 0.2),
        topRight: Offset(0.8, 0.2),
        bottomRight: Offset(0.8, 0.8),
        bottomLeft: Offset(0.2, 0.8),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 200,
              height: 200,
              child: StatefulBuilder(
                builder: (context, setState) => DocumentQuadOverlay(
                  corners: corners,
                  onChanged: (value) => setState(() => corners = value),
                ),
              ),
            ),
          ),
        ),
      );

      final origin = tester.getTopLeft(find.byType(DocumentQuadOverlay));
      final gesture = await tester.startGesture(origin + const Offset(40, 40));
      await tester.pump();
      await gesture.moveBy(const Offset(140, 140));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(corners.isValid, isTrue);
      expect(corners.topLeft, isNot(const Offset(0.9, 0.9)));
      expect(corners.topLeft.dy, lessThan(0.5));
    });
  });

  group('EdgeDocumentDetector', () {
    test('finds a bright sheet on a dark background', () {
      final photo = img.Image(width: 600, height: 800);
      img.fill(photo, color: img.ColorRgb8(38, 42, 46));

      const expected = DocumentCorners(
        topLeft: Offset(80 / 600, 120 / 800),
        topRight: Offset(520 / 600, 80 / 800),
        bottomRight: Offset(560 / 600, 700 / 800),
        bottomLeft: Offset(60 / 600, 660 / 800),
      );
      img.fillPolygon(
        photo,
        vertices: [
          img.Point(80, 120),
          img.Point(520, 80),
          img.Point(560, 700),
          img.Point(60, 660),
        ],
        color: img.ColorRgb8(245, 244, 240),
      );

      final detection = detectDocumentEdges(img.encodePng(photo));

      expect(detection.confidence, greaterThanOrEqualTo(0.55));
      expect(detection.corners.isValid, isTrue);

      for (var index = 0; index < 4; index++) {
        final found = detection.corners.points[index];
        final wanted = expected.points[index];
        expect(
          (found - wanted).distance,
          lessThan(0.05),
          reason: 'corner $index: $found vs $wanted',
        );
      }
    });

    test(
      'falls back to the full frame when the photo is one bright surface',
      () {
        final photo = img.Image(width: 300, height: 400);
        img.fill(photo, color: img.ColorRgb8(250, 250, 250));

        final detection = detectDocumentEdges(img.encodePng(photo));

        expect(detection.corners.isFullFrame, isTrue);
        expect(detection.confidence, greaterThan(0));
        expect(detection.note, isNotNull);
      },
    );

    test('reports low confidence for unreadable data', () {
      final detection = detectDocumentEdges(
        Uint8List.fromList(const [1, 2, 3, 4, 5]),
      );

      expect(detection.corners.isFullFrame, isTrue);
      expect(detection.confidence, 0);
      expect(detection.isConfident, isFalse);
    });
  });
}
