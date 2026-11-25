import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pindaiin/core/models/scanned_file.dart';
import 'package:pindaiin/core/services/file_access_service.dart';

ScannedFile _file({
  required FileKind kind,
  required FileOrigin origin,
  String name = 'file.pdf',
}) {
  return ScannedFile(
    id: 'id-$name',
    name: name,
    path: '/tmp/$name',
    kind: kind,
    sizeBytes: 1024,
    createdAt: DateTime(2026),
    origin: origin,
  );
}

void main() {
  group('Share MIME types', () {
    test('maps exported document and image formats', () {
      expect(
        FileAccessService.mimeTypeForPath('/tmp/scan.pdf'),
        'application/pdf',
      );
      expect(
        FileAccessService.mimeTypeForPath('/tmp/page.JPG'),
        'image/jpeg',
      );
      expect(
        FileAccessService.mimeTypeForPath('/tmp/page.png'),
        'image/png',
      );
      expect(
        FileAccessService.mimeTypeForPath('/tmp/report.docx'),
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      );
      expect(
        FileAccessService.mimeTypeForPath('/tmp/sheet.XLSX'),
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      );
    });

    test('falls back to a binary stream for unknown extensions', () {
      expect(
        FileAccessService.mimeTypeForPath('/tmp/archive.unknown'),
        'application/octet-stream',
      );
    });
  });

  group('Share validation', () {
    final service = FileAccessService();

    test('rejects an empty selection with a friendly message', () async {
      await expectLater(
        service.shareFiles(const []),
        throwsA(
          isA<ShareException>().having(
            (error) => error.message,
            'message',
            contains('No files selected'),
          ),
        ),
      );
    });

    test('rejects files that no longer exist', () async {
      final missing = '${Directory.systemTemp.path}/pindaiin_missing_'
          '${DateTime.now().microsecondsSinceEpoch}.pdf';

      await expectLater(
        service.shareFiles([missing]),
        throwsA(
          isA<ShareException>().having(
            (error) => error.message,
            'message',
            contains('missing'),
          ),
        ),
      );
    });
  });

  group('FileHubFilter', () {
    final scanPdf = _file(
      kind: FileKind.pdf,
      origin: FileOrigin.scan,
      name: 'scan.pdf',
    );
    final scanImage = _file(
      kind: FileKind.image,
      origin: FileOrigin.scan,
      name: 'page.jpg',
    );
    final convertedPdf = _file(
      kind: FileKind.pdf,
      origin: FileOrigin.conversion,
      name: 'converted.pdf',
    );
    final importedDoc = _file(
      kind: FileKind.document,
      origin: FileOrigin.import,
      name: 'note.docx',
    );

    test('All matches every file', () {
      for (final file in [scanPdf, scanImage, convertedPdf, importedDoc]) {
        expect(FileHubFilter.all.matches(file), isTrue);
      }
    });

    test('Scans matches only scanner exports', () {
      expect(FileHubFilter.scans.matches(scanPdf), isTrue);
      expect(FileHubFilter.scans.matches(scanImage), isTrue);
      expect(FileHubFilter.scans.matches(convertedPdf), isFalse);
      expect(FileHubFilter.scans.matches(importedDoc), isFalse);
    });

    test('PDFs matches every PDF regardless of origin', () {
      expect(FileHubFilter.pdfs.matches(scanPdf), isTrue);
      expect(FileHubFilter.pdfs.matches(convertedPdf), isTrue);
      expect(FileHubFilter.pdfs.matches(scanImage), isFalse);
    });

    test('Converted matches only conversion outputs', () {
      expect(FileHubFilter.converted.matches(convertedPdf), isTrue);
      expect(FileHubFilter.converted.matches(scanPdf), isFalse);
      expect(FileHubFilter.converted.matches(importedDoc), isFalse);
    });
  });
}
