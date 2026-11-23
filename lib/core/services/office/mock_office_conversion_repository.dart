import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../models/conversion.dart';
import 'office_conversion_models.dart';
import 'office_conversion_repository.dart';

/// Offline stand-in for a real conversion backend.
///
/// It simulates upload/convert/download progress and produces *valid* but
/// clearly-labelled placeholder files, so the whole client flow (progress,
/// history registration, preview/share) can be exercised without a server.
/// Replace it with [RestOfficeConversionRepository] for real conversions.
class MockOfficeConversionRepository implements OfficeConversionRepository {
  MockOfficeConversionRepository({
    this.stepLatency = const Duration(milliseconds: 160),
  });

  /// Delay between simulated progress steps.
  final Duration stepLatency;

  @override
  bool get isRemote => false;

  @override
  String get backendLabel => 'Demo converter (no backend configured)';

  @override
  int get maxUploadBytes => 25 * 1024 * 1024;

  @override
  Future<void> dispose() async {}

  @override
  Future<OfficeConversionResponse> convert(
    OfficeConversionRequest request, {
    OfficeProgressCallback? onProgress,
  }) async {
    // Upload 0..0.7, server work 0.7..0.8, download 0.8..0.95; the converter
    // adapter reports 0.95..1.0 while saving.
    for (var step = 1; step <= 4; step++) {
      await _report(
        onProgress,
        OfficeConversionStage.uploading,
        0.7 * step / 4,
      );
    }
    for (var step = 1; step <= 3; step++) {
      await _report(
        onProgress,
        OfficeConversionStage.converting,
        0.7 + 0.1 * step / 3,
      );
    }

    final bytes = await Isolate.run(
      () => _buildPlaceholder(request.target, request.inputFileName),
    );

    for (var step = 1; step <= 2; step++) {
      await _report(
        onProgress,
        OfficeConversionStage.downloading,
        0.8 + 0.15 * step / 2,
      );
    }

    final base = request.inputFileName.split('.').first;
    return OfficeConversionResponse(
      bytes: bytes,
      serverFileName: '${base}_demo.${request.target.extension}',
      jobId: 'mock-job',
    );
  }

  Future<void> _report(
    OfficeProgressCallback? onProgress,
    OfficeConversionStage stage,
    double fraction,
  ) async {
    onProgress?.call(OfficeProgress(stage, fraction));
    await Future<void>.delayed(stepLatency);
  }
}

Future<Uint8List> _buildPlaceholder(
  OfficeTarget target,
  String sourceName,
) async {
  return switch (target) {
    OfficeTarget.pdf => _buildPdf(sourceName),
    OfficeTarget.docx => _buildDocx(sourceName),
    OfficeTarget.xlsx => _buildXlsx(sourceName),
  };
}

Future<Uint8List> _buildPdf(String sourceName) async {
  final document = pw.Document();
  document.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(48),
      build: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            'Pindaiin demo conversion',
            style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 16),
          pw.Text('Source: $sourceName'),
          pw.SizedBox(height: 8),
          pw.Text(
            'This PDF was generated locally by the mock Office converter. '
            'Connect a real conversion backend (OFFICE_API_URL) to render the '
            'actual document with full fidelity.',
          ),
        ],
      ),
    ),
  );
  return document.save();
}

Uint8List _buildDocx(String sourceName) {
  const contentTypes = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>''';

  const relationships = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>''';

  final document = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>Pindaiin demo conversion</w:t></w:r></w:p>
    <w:p><w:r><w:t>Source: ${_escapeXml(sourceName)}</w:t></w:r></w:p>
    <w:p><w:r><w:t>This document was produced by the local mock converter. Configure OFFICE_API_URL for real PDF to Word conversion.</w:t></w:r></w:p>
    <w:sectPr/>
  </w:body>
</w:document>''';

  final archive = Archive()
    ..addFile(ArchiveFile.string('[Content_Types].xml', contentTypes))
    ..addFile(ArchiveFile.string('_rels/.rels', relationships))
    ..addFile(ArchiveFile.string('word/document.xml', document));

  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Uint8List _buildXlsx(String sourceName) {
  const contentTypes = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
  <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
</Types>''';

  const relationships = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>''';

  const workbook = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
          xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets>
</workbook>''';

  const workbookRelationships = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
</Relationships>''';

  final sheet = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <sheetData>
    <row r="1"><c r="A1" t="inlineStr"><is><t>Pindaiin demo conversion</t></is></c></row>
    <row r="2"><c r="A2" t="inlineStr"><is><t>Source: ${_escapeXml(sourceName)}</t></is></c></row>
    <row r="3"><c r="A3" t="inlineStr"><is><t>Generated locally by the mock Office converter.</t></is></c></row>
  </sheetData>
</worksheet>''';

  final archive = Archive()
    ..addFile(ArchiveFile.string('[Content_Types].xml', contentTypes))
    ..addFile(ArchiveFile.string('_rels/.rels', relationships))
    ..addFile(ArchiveFile.string('xl/workbook.xml', workbook))
    ..addFile(
      ArchiveFile.string('xl/_rels/workbook.xml.rels', workbookRelationships),
    )
    ..addFile(ArchiveFile.string('xl/worksheets/sheet1.xml', sheet));

  return Uint8List.fromList(ZipEncoder().encode(archive));
}

String _escapeXml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
