import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import '../models/scanned_file.dart';

/// Local metadata store backed by Hive.
///
/// Records are stored as JSON strings so no code generation/build_runner step
/// is required. The repository is a [ChangeNotifier] so every screen showing
/// the history refreshes after a scan, conversion, rename or delete.
class FileRepository extends ChangeNotifier {
  FileRepository();

  static const _boxName = 'files_v1';

  Box<String>? _box;
  final List<ScannedFile> _files = [];
  bool _ready = false;

  bool get isReady => _ready;

  /// Newest first.
  List<ScannedFile> get files => List.unmodifiable(_files);

  Future<void> open() async {
    if (_box != null) return;
    _box = await Hive.openBox<String>(_boxName);
    _files
      ..clear()
      ..addAll(
        _box!.values.map(_decode).whereType<ScannedFile>(),
      );
    _sort();
    _ready = true;
    notifyListeners();
  }

  Future<void> save(ScannedFile file) async {
    final box = _box ?? await Hive.openBox<String>(_boxName);
    _box = box;
    _files.removeWhere((existing) => existing.id == file.id);
    _files.add(file);
    _sort();
    await box.put(file.id, jsonEncode(file.toJson()));
    notifyListeners();
  }

  Future<void> delete(String id) async {
    _files.removeWhere((file) => file.id == id);
    await _box?.delete(id);
    notifyListeners();
  }

  Future<void> clear() async {
    _files.clear();
    await _box?.clear();
    notifyListeners();
  }

  ScannedFile? byId(String id) {
    for (final file in _files) {
      if (file.id == id) return file;
    }
    return null;
  }

  ScannedFile? _decode(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is Map<String, dynamic>) return ScannedFile.fromJson(json);
    } on FormatException {
      // Ignore corrupted entries instead of breaking the whole history.
    }
    return null;
  }

  void _sort() => _files.sort((a, b) => b.createdAt.compareTo(a.createdAt));
}
