import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:pindaiin/core/document/document_processor.dart';
import 'package:pindaiin/core/services/app_directories.dart';
import 'package:pindaiin/core/services/app_services.dart';
import 'package:pindaiin/core/services/file_storage_service.dart';
import 'package:pindaiin/features/scanner/scan_controller.dart';

/// A bright, skewed sheet on a dark background: the detector is confident here,
/// which is exactly the case that used to be warped without asking.
Uint8List _confidentPhoto() {
  final photo = img.Image(width: 600, height: 800);
  img.fill(photo, color: img.ColorRgb8(38, 42, 46));
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
  return Uint8List.fromList(img.encodePng(photo));
}

void main() {
  late Directory root;
  late ScanController controller;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pindaiin_capture_');
    Future<Directory> folder(String name) =>
        Directory(p.join(root.path, name)).create(recursive: true);

    controller = ScanController(
      services: AppServices.forTesting(
        directories: AppDirectories.forTesting(
          scans: await folder('scans'),
          exports: await folder('exports'),
          sessions: await folder('sessions'),
          temp: await folder('temp'),
        ),
        storage: FileStorageService(),
        documents: DocumentProcessor(),
      ),
    );
  });

  tearDown(() async {
    controller.dispose();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('a confident capture is added uncropped until the corners are confirmed',
      () async {
    final source = File(p.join(root.path, 'photo.png'));
    await source.writeAsBytes(_confidentPhoto());

    final result = await controller.addCapturedPhoto(source.path);

    expect(result, isNotNull);
    // Detection was confident, so the old capture path would have warped here.
    expect(result!.detection.isConfident, isTrue);
    expect(result.detection.corners.isFullFrame, isFalse);

    final sessionRoot = p.join(root.path, 'sessions');
    final captured = controller.pages[result.index];
    expect(captured.sourceImagePath, isNull);
    expect(p.isWithin(sessionRoot, captured.imagePath), isTrue);
    expect(p.basename(captured.imagePath), 'photo.png');
    // Byte-identical copy: the full-resolution photo is untouched.
    expect(await File(captured.imagePath).readAsBytes(), await source.readAsBytes());
    // Nothing was rendered into the session folder before confirmation.
    final sessionFiles = Directory(sessionRoot)
        .listSync(recursive: true)
        .whereType<File>()
        .map((file) => p.basename(file.path));
    expect(sessionFiles.where((name) => name.endsWith('_straight.jpg')), isEmpty);

    // Confirming the editor with the same detection is what warps the page.
    await controller.applyDocumentCorners(result.index, result.detection.corners);

    final straightened = controller.pages[result.index];
    expect(straightened.sourceImagePath, captured.imagePath);
    expect(straightened.imagePath, endsWith('_straight.jpg'));
    expect(await File(straightened.imagePath).length(), greaterThan(0));
    expect(straightened.quarterTurns, 0);
  });

  test('skip review: a confident page is straightened during capture',
      () async {
    final source = File(p.join(root.path, 'fast.png'));
    await source.writeAsBytes(_confidentPhoto());

    final result = await controller.addCapturedPhoto(
      source.path,
      skipReview: true,
    );

    expect(result, isNotNull);
    expect(result!.straightened, isTrue);
    final page = controller.pages[result.index];
    expect(page.imagePath, endsWith('_straight.jpg'));
    expect(page.sourceImagePath, isNotNull);
    expect(await File(page.imagePath).length(), greaterThan(0));
    // The full-resolution capture is still available for later re-adjustment.
    expect(await File(page.sourceImagePath!).length(), await source.length());
  });

  test('skip review: an unclear page still waits for the editor', () async {
    final source = File(p.join(root.path, 'fast_broken.png'));
    await source.writeAsBytes(Uint8List.fromList(const [1, 2, 3, 4, 5]));

    final result = await controller.addCapturedPhoto(
      source.path,
      skipReview: true,
    );

    expect(result, isNotNull);
    expect(result!.straightened, isFalse);
    expect(controller.pages[result.index].sourceImagePath, isNull);
    expect(controller.pages[result.index].imagePath, endsWith('.png'));
  });

  test('a capture whose detection fails is still added for manual review',
      () async {
    final source = File(p.join(root.path, 'broken.png'));
    await source.writeAsBytes(Uint8List.fromList(const [1, 2, 3, 4, 5]));

    final result = await controller.addCapturedPhoto(source.path);

    expect(result, isNotNull);
    expect(result!.detection.isConfident, isFalse);
    expect(controller.pageCount, 1);
    expect(controller.pages[result.index].sourceImagePath, isNull);
    expect(await File(controller.pages[result.index].imagePath).exists(), isTrue);
    expect(controller.error, isNull);
  });
}
