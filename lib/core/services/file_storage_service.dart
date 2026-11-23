import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Low-level filesystem helpers. Metadata lives in [FileRepository]; this
/// service owns the actual bytes on disk.
class FileStorageService {
  /// Writes [bytes] into [directory] and returns the final path. Existing names
  /// are never overwritten: `name (2).ext` is used instead.
  Future<String> writeBytes({
    required Directory directory,
    required String fileName,
    required Uint8List bytes,
  }) async {
    await directory.create(recursive: true);
    final path = await _uniquePath(directory, sanitizeFileName(fileName));
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
    return path;
  }

  /// Non-allocating name reservation used when another service writes the file.
  Future<String> uniquePathIn(Directory directory, String fileName) async {
    await directory.create(recursive: true);
    return _uniquePath(directory, sanitizeFileName(fileName));
  }

  /// Copies an externally picked file into [directory], preserving extension.
  Future<String> copyIntoDirectory(String sourcePath, Directory directory) async {
    await directory.create(recursive: true);
    final path = await _uniquePath(directory, sanitizeFileName(p.basename(sourcePath)));
    return (await File(sourcePath).copy(path)).path;
  }

  /// Renames the physical file; returns the new path. Falls back to the old
  /// path if the file is missing.
  Future<String> rename(String path, String newName) async {
    final file = File(path);
    if (!await file.exists()) return path;
    final clean = sanitizeFileName(newName);
    final target = p.join(file.parent.path, clean);
    if (p.equals(target, path)) return path;
    if (await File(target).exists()) {
      throw FileSystemException('A file named "$clean" already exists.', target);
    }
    return (await file.rename(target)).path;
  }

  Future<int> sizeOf(String path) async {
    final file = File(path);
    if (!await file.exists()) return 0;
    return file.length();
  }

  Future<void> deleteQuietly(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // The metadata is removed regardless; an already-missing file is fine.
    }
  }

  Future<void> deleteDirectoryQuietly(String path) async {
    try {
      final dir = Directory(path);
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // Best effort cleanup.
    }
  }

  /// Removes characters that are invalid on common filesystems and trims length.
  String sanitizeFileName(String input) {
    var name = input.trim().replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_');
    name = name.replaceAll(RegExp(r'\s+'), ' ');
    if (name.isEmpty) name = 'file';
    if (name.length > 120) {
      final ext = p.extension(name);
      final base = p.basenameWithoutExtension(name);
      name = '${base.substring(0, 120 - ext.length)}${ext.length > 12 ? '' : ext}';
    }
    return name;
  }

  Future<String> _uniquePath(Directory directory, String fileName) async {
    var candidate = p.join(directory.path, fileName);
    if (!await File(candidate).exists()) return candidate;

    final ext = p.extension(fileName);
    final base = p.basenameWithoutExtension(fileName);
    var index = 2;
    while (await File(candidate).exists()) {
      candidate = p.join(directory.path, '$base ($index)$ext');
      index++;
    }
    return candidate;
  }
}
