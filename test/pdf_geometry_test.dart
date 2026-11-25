import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pindaiin/core/pdf/pdf_geometry.dart';

void main() {
  group('PdfGeometry rotation', () {
    test('maps unrotated corners clockwise and back', () {
      const point = Offset(0.2, 0.3);
      for (var turns = 0; turns < 4; turns++) {
        final display = PdfGeometry.unrotatedToDisplay(point, turns);
        final back = PdfGeometry.displayToUnrotated(display, turns);
        expect(back.dx, closeTo(point.dx, 1e-9));
        expect(back.dy, closeTo(point.dy, 1e-9));
      }
    });

    test('90 degree mapping sends top-left to top-right', () {
      expect(
        PdfGeometry.unrotatedToDisplay(const Offset(0, 0), 1),
        const Offset(1, 0),
      );
      expect(
        PdfGeometry.unrotatedToDisplay(const Offset(1, 0), 1),
        const Offset(1, 1),
      );
    });

    test('rotates a rectangle and keeps its area', () {
      const rect = Rect.fromLTWH(0.1, 0.2, 0.3, 0.4);
      final rotated = PdfGeometry.rectUnrotatedToDisplay(rect, 1);
      expect(rotated.width, closeTo(rect.height, 1e-9));
      expect(rotated.height, closeTo(rect.width, 1e-9));
      expect(rotated.left, closeTo(0.4, 1e-9));
      expect(rotated.top, closeTo(0.1, 1e-9));
    });

    test('converts display coordinates to y-up PDF points', () {
      final points = PdfGeometry.toPdfPoints(
        rect: const Rect.fromLTWH(0.1, 0.2, 0.4, 0.5),
        quarterTurns: 0,
        pageWidth: 1000,
        pageHeight: 800,
      );
      expect(points.left, closeTo(100, 1e-9));
      expect(points.right, closeTo(500, 1e-9));
      expect(points.bottom, closeTo(240, 1e-9));
      expect(points.top, closeTo(640, 1e-9));
    });
  });
}
