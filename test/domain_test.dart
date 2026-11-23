import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pindaiin/core/models/scan_page.dart';
import 'package:pindaiin/core/models/scanned_file.dart';
import 'package:pindaiin/core/services/file_storage_service.dart';

void main() {
  group('ScanPage rotation', () {
    test('rotating clockwise copies the crop with the image', () {
      const page = ScanPage(
        id: 'p1',
        imagePath: '/tmp/a.jpg',
        crop: Rect.fromLTRB(0.1, 0.2, 0.5, 0.6),
      );

      final rotated = page.rotatedClockwise();

      expect(rotated.quarterTurns, 1);
      expect(rotated.crop.left, closeTo(0.4, 1e-9));
      expect(rotated.crop.top, closeTo(0.1, 1e-9));
      expect(rotated.crop.width, closeTo(0.4, 1e-9));
      expect(rotated.crop.height, closeTo(0.4, 1e-9));
    });

    test('four clockwise turns restore rotation and crop', () {
      const page = ScanPage(
        id: 'p1',
        imagePath: '/tmp/a.jpg',
        crop: Rect.fromLTRB(0.15, 0.05, 0.7, 0.55),
      );

      final result = page
          .rotatedClockwise()
          .rotatedClockwise()
          .rotatedClockwise()
          .rotatedClockwise();

      expect(result.quarterTurns, 0);
      expect(result.crop.left, closeTo(page.crop.left, 1e-9));
      expect(result.crop.top, closeTo(page.crop.top, 1e-9));
      expect(result.crop.width, closeTo(page.crop.width, 1e-9));
      expect(result.crop.height, closeTo(page.crop.height, 1e-9));
    });

    test('counter-clockwise is the inverse of clockwise', () {
      const page = ScanPage(
        id: 'p1',
        imagePath: '/tmp/a.jpg',
        crop: Rect.fromLTRB(0.12, 0.34, 0.56, 0.78),
      );

      final roundTrip = page.rotatedClockwise().rotatedCounterClockwise();

      expect(roundTrip.quarterTurns, 0);
      expect(roundTrip.crop.left, closeTo(page.crop.left, 1e-9));
      expect(roundTrip.crop.top, closeTo(page.crop.top, 1e-9));
      expect(roundTrip.crop.width, closeTo(page.crop.width, 1e-9));
      expect(roundTrip.crop.height, closeTo(page.crop.height, 1e-9));
    });

    test('hasCrop ignores a full-frame crop', () {
      const full = ScanPage(id: 'a', imagePath: '/tmp/a.jpg');
      final cropped = full.copyWith(crop: const Rect.fromLTRB(0, 0, 0.5, 1));
      expect(full.hasCrop, isFalse);
      expect(cropped.hasCrop, isTrue);
    });
  });

  group('ScannedFile JSON', () {
    test('survives an encode/decode round trip', () {
      final file = ScannedFile(
        id: 'abc',
        name: 'Scan_20260101_120000.pdf',
        path: '/data/scans/Scan_20260101_120000.pdf',
        kind: FileKind.pdf,
        sizeBytes: 2048,
        createdAt: DateTime.fromMillisecondsSinceEpoch(1767268800000),
        origin: FileOrigin.scan,
        pageCount: 3,
      );

      final decoded = ScannedFile.fromJson(
        jsonDecode(jsonEncode(file.toJson())) as Map<String, dynamic>,
      );

      expect(decoded.id, file.id);
      expect(decoded.name, file.name);
      expect(decoded.path, file.path);
      expect(decoded.kind, FileKind.pdf);
      expect(decoded.sizeBytes, file.sizeBytes);
      expect(decoded.createdAt, file.createdAt);
      expect(decoded.origin, FileOrigin.scan);
      expect(decoded.pageCount, 3);
    });

    test('falls back safely for unknown enums', () {
      final decoded = ScannedFile.fromJson({
        'id': 'x',
        'name': 'note.weird',
        'path': '/tmp/note.weird',
        'kind': 'not-a-kind',
        'origin': 'not-an-origin',
      });

      expect(decoded.kind, FileKind.other);
      expect(decoded.origin, FileOrigin.import);
      expect(decoded.sizeBytes, 0);
    });
  });

  group('fileKindFromPath', () {
    test('maps common extensions case-insensitively', () {
      expect(fileKindFromPath('/tmp/photo.JPG'), FileKind.image);
      expect(fileKindFromPath('/tmp/doc.pdf'), FileKind.pdf);
      expect(fileKindFromPath('/tmp/report.DOCX'), FileKind.document);
      expect(fileKindFromPath('/tmp/sheet.xlsx'), FileKind.spreadsheet);
      expect(fileKindFromPath('/tmp/archive.zip'), FileKind.other);
    });
  });

  group('FileStorageService.sanitizeFileName', () {
    final storage = FileStorageService();

    test('replaces path separators and reserved characters', () {
      expect(storage.sanitizeFileName('a/b:c*d?.pdf'), 'a_b_c_d_.pdf');
    });

    test('falls back to "file" and keeps the extension when truncating', () {
      expect(storage.sanitizeFileName('   '), 'file');
      final long = '${'x' * 200}.pdf';
      final sanitized = storage.sanitizeFileName(long);
      expect(sanitized.length, lessThanOrEqualTo(120));
      expect(sanitized.endsWith('.pdf'), isTrue);
    });
  });
}
