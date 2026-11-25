import 'dart:io';
import 'dart:ui' show Rect;

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

/// Result of handing files to the system share sheet.
class ShareOutcome {
  const ShareOutcome({
    required this.sharedCount,
    required this.skippedPaths,
    required this.dismissed,
  });

  /// Files that were handed to the share sheet.
  final int sharedCount;

  /// Files skipped because they no longer exist or are empty.
  final List<String> skippedPaths;

  /// True when the platform reported that the user closed the sheet without
  /// picking a target. Not an error.
  final bool dismissed;

  bool get hasSkipped => skippedPaths.isNotEmpty;
}

/// User-facing sharing failure (nothing shareable, plugin unavailable, …).
class ShareException implements Exception {
  const ShareException(this.message);

  final String message;

  @override
  String toString() => 'ShareException: $message';
}

/// Wraps the platform intents (camera, gallery, SAF picker, share sheet, open
/// with) so features stay free of plugin-specific code and easy to test.
class FileAccessService {
  FileAccessService({ImagePicker? picker}) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  static const imageExtensions = ['jpg', 'jpeg', 'png', 'webp'];

  /// MIME types used for the share sheet. Receiving apps (WhatsApp, Gmail,
  /// Drive, Bluetooth, …) use these to decide how to handle the file, so they
  /// must match the actual extension rather than a generic octet-stream.
  static const Map<String, String> _mimeTypes = {
    '.pdf': 'application/pdf',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.png': 'image/png',
    '.webp': 'image/webp',
    '.gif': 'image/gif',
    '.bmp': 'image/bmp',
    '.heic': 'image/heic',
    '.doc': 'application/msword',
    '.docx':
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    '.xls': 'application/vnd.ms-excel',
    '.xlsx':
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    '.csv': 'text/csv',
    '.txt': 'text/plain',
    '.zip': 'application/zip',
  };

  static String mimeTypeForPath(String path) =>
      _mimeTypes[p.extension(path).toLowerCase()] ?? 'application/octet-stream';

  /// One photo per invocation; the camera activity closes after each shot.
  Future<List<String>> capturePhoto() async {
    final file = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 95,
      requestFullMetadata: false,
    );
    return file == null ? const [] : [file.path];
  }

  Future<List<String>> pickFromGallery() async {
    final files = await _picker.pickMultiImage(
      imageQuality: 95,
      requestFullMetadata: false,
    );
    return files.map((file) => file.path).toList(growable: false);
  }

  /// System file picker. Returns an empty list when the user cancels.
  Future<List<String>> pickFiles({
    List<String>? allowedExtensions,
    bool allowMultiple = true,
  }) async {
    final type = allowedExtensions == null ? FileType.any : FileType.custom;
    if (allowMultiple) {
      final files = await FilePicker.pickFiles(
        type: type,
        allowedExtensions: allowedExtensions,
      );
      return files.map((file) => file.path).whereType<String>().toList();
    }

    final file = await FilePicker.pickFile(
      type: type,
      allowedExtensions: allowedExtensions,
    );
    final path = file?.path;
    return path == null ? const [] : [path];
  }

  /// Shares one or more files through the Android/iOS system share sheet.
  ///
  /// Files are validated first: paths that no longer exist (deleted outside the
  /// app, stale Hive records) or are empty are skipped instead of crashing the
  /// share intent. If nothing usable remains, a [ShareException] is thrown with
  /// a message suitable for a snackbar. Each [XFile] carries its MIME type.
  Future<ShareOutcome> shareFiles(
    List<String> paths, {
    String? subject,
    Rect? sharePositionOrigin,
  }) async {
    if (paths.isEmpty) {
      throw const ShareException('No files selected to share.');
    }

    final files = <XFile>[];
    final skipped = <String>[];
    for (final path in paths) {
      final file = File(path);
      var readable = false;
      try {
        readable = await file.exists() && await file.length() > 0;
      } catch (_) {
        readable = false;
      }
      if (!readable) {
        skipped.add(path);
        continue;
      }
      files.add(XFile(path, mimeType: mimeTypeForPath(path)));
    }

    if (files.isEmpty) {
      throw const ShareException(
        'The file is missing, empty, or no longer readable. Export it again.',
      );
    }

    try {
      final result = await SharePlus.instance.share(
        ShareParams(
          files: files,
          subject: subject,
          sharePositionOrigin: sharePositionOrigin,
        ),
      );
      return ShareOutcome(
        sharedCount: files.length,
        skippedPaths: skipped,
        dismissed: result.status == ShareResultStatus.dismissed,
      );
    } catch (error) {
      throw ShareException(
        'Could not open the share sheet. '
        '${_clean(error)}',
      );
    }
  }

  Future<OpenResult> openExternally(String path) => OpenFilex.open(path);

  static String _clean(Object error) {
    final message = error.toString();
    return message.replaceFirst(RegExp(r'^[A-Za-z]+Exception: '), '');
  }
}
