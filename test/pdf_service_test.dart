import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart' hide PdfColor, PdfEncryption, PdfRect;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf_manipulator/io.dart';
import 'package:pdf_manipulator/pdf_manipulator.dart';
import 'package:pindaiin/core/models/pdf_edit.dart';
import 'package:pindaiin/core/services/pdf_service.dart';

Future<File> _samplePdf(Directory dir, List<String> labels) async {
  final doc = pw.Document();
  for (final label in labels) {
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (_) => pw.Center(child: pw.Text(label)),
      ),
    );
  }
  final file = File('${dir.path}/sample_${DateTime.now().microsecondsSinceEpoch}.pdf');
  await file.writeAsBytes(await doc.save());
  return file;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  final service = PdfService();

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('pindaiin_pdf_test');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('opens, reports info, renders and searches a PDF', () async {
    final source = await _samplePdf(dir, ['Alpha', 'Beta', 'Gamma']);
    final session = await service.open(source.path);
    addTearDown(session.close);

    expect(session.pageCount, 3);
    final info = await service.fileInfo(source.path, session);
    expect(info.pageCount, 3);
    expect(info.isEncrypted, isFalse);
    expect(info.sizeBytes, greaterThan(0));

    final png = await session.render(0, maxWidth: 500);
    expect(png.length, greaterThan(100));
    expect(png.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);

    final hits = await session.search('Beta');
    expect(hits, hasLength(1));
    expect(hits.single.page, 1);
    expect(hits.single.bounds.width, greaterThan(0));

    expect(await session.classify(0), PdfPageKind.textLayer);
    expect(await session.text(0), contains('Alpha'));
  });

  test('saves reorder, rotation, text replacement and markup', () async {
    final source = await _samplePdf(dir, ['Alpha', 'Beta', 'Gamma']);
    final input = await service.open(source.path);
    final metrics = input.pages;
    await input.close();

    final pages = [
      PdfPageRef(
        id: 'p1',
        sourcePage: 1,
        width: metrics[1].width,
        height: metrics[1].height,
        initialQuarterTurns: metrics[1].quarterTurns,
        rotationDelta: 1,
      ),
      PdfPageRef(
        id: 'p0',
        sourcePage: 0,
        width: metrics[0].width,
        height: metrics[0].height,
        initialQuarterTurns: metrics[0].quarterTurns,
      ),
      PdfPageRef(
        id: 'p2',
        sourcePage: 2,
        width: metrics[2].width,
        height: metrics[2].height,
        initialQuarterTurns: metrics[2].quarterTurns,
      ),
    ];

    final search = await service.open(source.path);
    final hit = (await search.search('Beta')).single;
    await search.close();

    final output = File('${dir.path}/edited.pdf');
    await service.saveEdits(
      sourcePath: source.path,
      outputPath: output.path,
      pages: pages,
      marks: [
        PdfMark(
          id: 'm1',
          pageId: 'p0',
          kind: PdfMarkKind.text,
          rect: const Rect.fromLTWH(0.1, 0.1, 0.4, 0.05),
          text: 'Reviewed',
          fontSize: 0.03,
        ),
        PdfMark(
          id: 'm2',
          pageId: 'p0',
          kind: PdfMarkKind.highlight,
          rect: const Rect.fromLTWH(0.1, 0.2, 0.3, 0.04),
          colorValue: 0xFFFFEB3B,
          opacity: 0.35,
        ),
      ],
      textEdits: [
        PdfTextReplacement(
          pageId: 'p1',
          sourcePage: 1,
          original: hit.text,
          replacement: 'Delta',
          left: hit.bounds.left,
          bottom: hit.bounds.bottom,
          right: hit.bounds.right,
          top: hit.bounds.top,
        ),
      ],
    );

    expect(await output.exists(), isTrue);
    final result = await service.open(output.path);
    addTearDown(result.close);
    expect(result.pageCount, 3);
    expect(result.pages[0].quarterTurns, 1);
    // Redaction removes the old run; the visible replacement is a foreground
    // stamp, so the text layer no longer contains "Beta".
    expect(await result.text(0), isNot(contains('Beta')));
    expect(await result.text(1), contains('Alpha'));

    // The replacement must actually be visible, not just absent from the text
    // layer: render the page and count dark glyph pixels.
    final rendered = img.decodePng(await result.render(0, maxWidth: 500));
    expect(rendered, isNotNull);
    var nonWhite = 0;
    for (final pixel in rendered!) {
      if (pixel.r < 200) nonWhite++;
    }
    expect(nonWhite, greaterThan(20));
  });

  test('merges and extracts pages', () async {
    final first = await _samplePdf(dir, ['One']);
    final second = await _samplePdf(dir, ['Two']);

    final mergedPath = '${dir.path}/merged.pdf';
    await service.merge(inputPaths: [first.path, second.path], outputPath: mergedPath);
    final merged = await service.open(mergedPath);
    expect(merged.pageCount, 2);
    expect(await merged.text(1), contains('Two'));
    await merged.close();

    final extractedPath = '${dir.path}/extracted.pdf';
    await service.extractPages(
      sourcePath: mergedPath,
      pages: [1],
      outputPath: extractedPath,
    );
    final extracted = await service.open(extractedPath);
    expect(extracted.pageCount, 1);
    expect(await extracted.text(0), contains('Two'));
    await extracted.close();
  });

  test('prompts for and checks a PDF password', () async {
    final source = await _samplePdf(dir, ['Secret']);
    final encrypted = File('${dir.path}/encrypted.pdf');
    final pdf = Pdf();
    final sink = await FileSink.open(encrypted);
    await pdf.rewrite(
      PdfFile(source),
      sink,
      (editor) async {},
      save: const PdfSave.full(
        encryption: PdfEncryption.password(
          ownerPassword: 'owner',
          userPassword: 'secret',
        ),
      ),
    );
    await sink.close();
    await pdf.dispose();

    await expectLater(
      service.open(encrypted.path),
      throwsA(
        isA<PdfFailure>().having(
          (failure) => failure.kind,
          'kind',
          PdfFailureKind.passwordRequired,
        ),
      ),
    );
    await expectLater(
      service.open(encrypted.path, password: 'nope'),
      throwsA(
        isA<PdfFailure>().having(
          (failure) => failure.kind,
          'kind',
          PdfFailureKind.wrongPassword,
        ),
      ),
    );
    final session = await service.open(encrypted.path, password: 'secret');
    expect(session.pageCount, 1);
    await session.close();
  });

  test('maps corrupt and missing files to friendly failures', () async {
    final corrupt = File('${dir.path}/broken.pdf')
      ..writeAsBytesSync([1, 2, 3, 4, 5]);
    await expectLater(
      service.open(corrupt.path),
      throwsA(
        isA<PdfFailure>().having(
          (failure) => failure.kind,
          'kind',
          PdfFailureKind.corrupted,
        ),
      ),
    );

    await expectLater(
      service.open('${dir.path}/missing.pdf'),
      throwsA(
        isA<PdfFailure>().having(
          (failure) => failure.kind,
          'kind',
          PdfFailureKind.io,
        ),
      ),
    );
  });
}
