import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../document/document_processor.dart';
import '../models/scanned_file.dart';
import 'app_directories.dart';
import 'document_converter_service.dart';
import 'file_access_service.dart';
import 'file_repository.dart';
import 'file_storage_service.dart';
import 'image_processor.dart';
import 'office/mock_office_conversion_repository.dart';
import 'office/office_conversion_repository.dart';
import 'office/repository_office_converter.dart';
import 'office/rest_office_conversion_repository.dart';
import 'pdf_converter.dart';
import 'pdf_service.dart';

/// Composition root: wires directories, storage, persistence and converters
/// once at startup, then exposes them through `provider`.
class AppServices {
  AppServices._({
    required this.directories,
    required this.storage,
    required this.repository,
    required this.fileAccess,
    required this.images,
    required this.documents,
    required this.pdf,
    required this.pdfEditor,
    required this.converter,
  });

  final AppDirectories directories;
  final FileStorageService storage;
  final FileRepository repository;
  final FileAccessService fileAccess;
  final ImageProcessor images;

  /// Document edge detection + perspective warp for scanned pages. Swap the
  /// detector or warper here to change the algorithm app-wide.
  final DocumentProcessor documents;

  final PdfConverter pdf;

  /// Reader/editor engine: metadata, rendering, text search and page edits.
  final PdfService pdfEditor;

  final DocumentConverterService converter;

  /// `--dart-define=OFFICE_API_URL=https://convert.example.com` switches from
  /// the mock to a real backend. `OFFICE_API_KEY` is optional and sent as a
  /// Bearer token.
  static const officeApiUrl = String.fromEnvironment('OFFICE_API_URL');
  static const officeApiKey = String.fromEnvironment('OFFICE_API_KEY');

  static Future<AppServices> bootstrap() async {
    final directories = await AppDirectories.create();
    final storage = FileStorageService();
    final repository = FileRepository();
    await repository.open();

    final pdf = LocalPdfConverter(storage: storage);
    final OfficeConversionRepository officeRepository = officeApiUrl.isEmpty
        ? MockOfficeConversionRepository()
        : RestOfficeConversionRepository(
            baseUrl: officeApiUrl,
            apiKey: officeApiKey.isEmpty ? null : officeApiKey,
          );
    final office = RepositoryOfficeConverter(repository: officeRepository);

    return AppServices._(
      directories: directories,
      storage: storage,
      repository: repository,
      fileAccess: FileAccessService(),
      images: const ImageProcessor(),
      documents: DocumentProcessor(),
      pdf: pdf,
      pdfEditor: PdfService(),
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

  /// Renames a registered file on disk and in the metadata store.
  ///
  /// Shared by the file hub and the post-scan/post-conversion summaries so the
  /// rename rules (sanitizing, keeping the extension, collision errors) live in
  /// one place. Throws when the target name already exists.
  Future<ScannedFile> renameFile(ScannedFile file, String rawName) async {
    var name = storage.sanitizeFileName(rawName);
    if (name.isEmpty) {
      throw ArgumentError('The file name cannot be empty.');
    }
    if (p.extension(name).isEmpty && file.extension.isNotEmpty) {
      name = '$name${file.extension}';
    }
    final newPath = await storage.rename(file.path, name);
    final updated = file.copyWith(name: name, path: newPath);
    await repository.save(updated);
    return updated;
  }

  /// Creates a fresh working folder for one scan session.
  Future<Directory> createSessionDirectory() async {
    final dir = Directory(
      p.join(directories.sessions.path, const Uuid().v4()),
    );
    return dir.create(recursive: true);
  }
}
