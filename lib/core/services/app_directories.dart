import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Resolves the app-private folders used by the app.
///
/// Everything lives inside the app sandbox (scoped storage friendly): no
/// `WRITE_EXTERNAL_STORAGE` is needed on Android 10+, and files leave the app
/// only through the system share sheet or SAF picker.
class AppDirectories {
  AppDirectories._({
    required this.scans,
    required this.exports,
    required this.sessions,
    required this.temp,
  });

  /// Builds the folder set from explicit directories, skipping the
  /// `path_provider` lookup so tests can work in a temp folder.
  @visibleForTesting
  factory AppDirectories.forTesting({
    required Directory scans,
    required Directory exports,
    required Directory sessions,
    required Directory temp,
  }) => AppDirectories._(
    scans: scans,
    exports: exports,
    sessions: sessions,
    temp: temp,
  );

  /// Exported scans (images / merged PDF).
  final Directory scans;

  /// Converter output.
  final Directory exports;

  /// Per-session working copies of newly captured/picked pages.
  final Directory sessions;

  /// Scratch space (PDF preview renders, intermediates).
  final Directory temp;

  static Future<AppDirectories> create() async {
    final documents = await getApplicationDocumentsDirectory();
    final cache = await getTemporaryDirectory();
    final root = documents.path;

    Future<Directory> ensure(String path) => Directory(path).create(recursive: true);

    return AppDirectories._(
      scans: await ensure(p.join(root, 'Pindaiin', 'scans')),
      exports: await ensure(p.join(root, 'Pindaiin', 'exports')),
      sessions: await ensure(p.join(cache.path, 'pindaiin_sessions')),
      temp: await ensure(p.join(cache.path, 'pindaiin_tmp')),
    );
  }
}
