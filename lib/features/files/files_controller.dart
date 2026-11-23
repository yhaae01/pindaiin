import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart' show ResultType;
import 'package:path/path.dart' as p;

import '../../core/models/scanned_file.dart';
import '../../core/services/app_services.dart';
import '../../core/services/file_repository.dart';
import '../../core/utils/formatters.dart';

/// View-model for the file hub: search, rename, delete and share.
///
/// It listens to [FileRepository] so exports made from other tabs appear here
/// without manual refreshes.
class FilesController extends ChangeNotifier {
  FilesController({required AppServices services})
    : _services = services,
      _repository = services.repository {
    _repository.addListener(_onRepositoryChanged);
  }

  final AppServices _services;
  final FileRepository _repository;

  String _query = '';
  bool _busy = false;
  String? _error;

  String get query => _query;
  bool get isBusy => _busy;
  String? get error => _error;

  /// Newest first, filtered by the current search query.
  List<ScannedFile> get files {
    final all = _repository.files;
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return all;
    return all
        .where((file) => file.name.toLowerCase().contains(query))
        .toList(growable: false);
  }

  int get totalCount => _repository.files.length;

  void setQuery(String value) {
    if (_query == value) return;
    _query = value;
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  Future<void> rename(ScannedFile file, String rawName) async {
    var name = _services.storage.sanitizeFileName(rawName);
    if (name.isEmpty) return;
    if (p.extension(name).isEmpty && file.extension.isNotEmpty) {
      name = Formatters.withExtension(name, file.extension.replaceFirst('.', ''));
    }

    _setBusy(true);
    try {
      final newPath = await _services.storage.rename(file.path, name);
      await _repository.save(file.copyWith(name: name, path: newPath));
      _error = null;
    } catch (error) {
      _error = error is Exception && error.toString().contains('already exists')
          ? 'A file named "$name" already exists.'
          : 'Rename failed: ${_clean(error)}';
    } finally {
      _setBusy(false);
    }
  }

  Future<void> delete(ScannedFile file) async {
    _setBusy(true);
    try {
      await _services.storage.deleteQuietly(file.path);
      await _repository.delete(file.id);
      _error = null;
    } finally {
      _setBusy(false);
    }
  }

  Future<void> share(ScannedFile file) async {
    try {
      await _services.fileAccess.shareFiles([file.path], subject: file.name);
    } catch (error) {
      _error = 'Could not open the share sheet: ${_clean(error)}';
      notifyListeners();
    }
  }

  Future<bool> open(ScannedFile file) async {
    try {
      final result = await _services.fileAccess.openExternally(file.path);
      if (result.type != ResultType.done) {
        _error = result.message.isEmpty
            ? 'No app can open this file.'
            : result.message;
        notifyListeners();
        return false;
      }
      return true;
    } catch (error) {
      _error = 'Could not open the file: ${_clean(error)}';
      notifyListeners();
      return false;
    }
  }

  void _setBusy(bool value) {
    _busy = value;
    notifyListeners();
  }

  void _onRepositoryChanged() => notifyListeners();

  String _clean(Object error) =>
      error.toString().replaceFirst(RegExp(r'^[A-Za-z]+Exception: '), '');

  @override
  void dispose() {
    _repository.removeListener(_onRepositoryChanged);
    super.dispose();
  }
}
