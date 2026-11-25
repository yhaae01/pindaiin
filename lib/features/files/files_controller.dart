import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart' show ResultType;

import '../../core/models/scanned_file.dart';
import '../../core/services/app_services.dart';
import '../../core/services/file_access_service.dart';
import '../../core/services/file_repository.dart';

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
  FileHubFilter _filter = FileHubFilter.all;
  bool _busy = false;
  String? _error;

  String get query => _query;
  FileHubFilter get filter => _filter;
  bool get isBusy => _busy;
  String? get error => _error;

  /// Newest first, filtered by the selected chip and then the search query.
  List<ScannedFile> get files {
    final query = _query.trim().toLowerCase();
    return _repository.files.where((file) {
      if (!_filter.matches(file)) return false;
      if (query.isEmpty) return true;
      return file.name.toLowerCase().contains(query);
    }).toList(growable: false);
  }

  int get totalCount => _repository.files.length;

  int countFor(FileHubFilter filter) =>
      _repository.files.where(filter.matches).length;

  void setQuery(String value) {
    if (_query == value) return;
    _query = value;
    notifyListeners();
  }

  void setFilter(FileHubFilter value) {
    if (_filter == value) return;
    _filter = value;
    notifyListeners();
  }

  void clearFilters() {
    if (_query.isEmpty && _filter == FileHubFilter.all) return;
    _query = '';
    _filter = FileHubFilter.all;
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  Future<void> rename(ScannedFile file, String rawName) async {
    _setBusy(true);
    try {
      await _services.renameFile(file, rawName);
      _error = null;
    } catch (error) {
      _error = error is Exception && error.toString().contains('already exists')
          ? 'A file named "${rawName.trim()}" already exists.'
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
      final outcome = await _services.fileAccess.shareFiles(
        [file.path],
        subject: file.name,
      );
      if (outcome.hasSkipped) {
        _error =
            'The file is missing or empty, so it could not be shared. '
            'Export it again if needed.';
      } else {
        _error = null;
      }
      notifyListeners();
    } on ShareException catch (error) {
      _error = error.message;
      notifyListeners();
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
