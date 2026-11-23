import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/scanned_file.dart';
import 'app_directories.dart';
import 'document_converter_service.dart';
import 'file_access_service.dart';
import 'file_repository.dart';
import 'file_storage_service.dart';
import 'image_processor.dart';
import 'office_converter.dart';
import 'pdf_converter.dart';

/// Composition root: wires directories, storage, persistence and converters
/// once at startup, then exposes them through `provider`.
class AppServices {
  AppServices._({
    required this.directories,
    required this.storage,
    required this.repository,
    required this.fileAccess,
    required this.images,
    required this.pdf,
    required this.converter,
  });

  final AppDirectories directories;
  final FileStorageService storage;
  final FileRepository repository;
  final FileAccessService fileAccess;
  final ImageProcessor images;
  final PdfConverter pdf;
  final DocumentConverterService converter;

  static Future<AppServices> bootstrap() async {
    final directories = await AppDirectories.create();
    final storage = FileStorageService();
    final repository = FileRepository();
    await repository.open();

    final pdf = LocalPdfConverter(storage: storage);
    final office = const UnavailableOfficeConverter();

    return AppServices._(
      directories: directories,
      storage: storage,
      repository: repository,
      fileAccess: FileAccessService(),
      images: const ImageProcessor(),
      pdf: pdf,
      converter: DocumentConverterService(pdf: pdf, office: office),
    );
  }

  /// Persists metadata for a file that was just written to disk so it shows up
  /// in the file hub immediately.
  Future<ScannedFile> registerFile({
    required String path,
    required FileOrigin origin,
    int? pageCount,
  }) async {
    final file = ScannedFile(
      id: const Uuid().v4(),
      name: p.basename(path),
      path: path,
      kind: fileKindFromPath(path),
      sizeBytes: await storage.sizeOf(path),
      createdAt: DateTime.now(),
      origin: origin,
      pageCount: pageCount,
    );
    await repository.save(file);
    return file;
  }

  /// Creates a fresh working folder for one scan session.
  Future<Directory> createSessionDirectory() async {
    final dir = Directory(
      p.join(directories.sessions.path, const Uuid().v4()),
    );
    return dir.create(recursive: true);
  }
}
