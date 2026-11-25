import 'package:flutter/foundation.dart';

import '../../core/models/conversion.dart';
import '../../core/models/scanned_file.dart';
import '../../core/services/app_services.dart';
import '../../core/services/file_access_service.dart';

/// Drives the converter UI: source selection, mode/quality and the conversion
/// itself. All heavy lifting stays behind [DocumentConverterService].
class ConverterController extends ChangeNotifier {
  ConverterController({required this.services});

  final AppServices services;

  ConversionMode _mode = ConversionMode.imagesToPdf;
  final List<String> _inputs = [];
  PdfQuality _quality = PdfQuality.balanced;
  bool _busy = false;
  double? _progress;
  String? _status;
  String? _error;
  List<ScannedFile> _outputs = [];

  ConversionMode get mode => _mode;
  List<String> get inputs => List.unmodifiable(_inputs);
  PdfQuality get quality => _quality;
  bool get isBusy => _busy;
  double? get progress => _progress;

  /// Stage label reported by the conversion service ("Uploading…").
  String? get statusText => _status;
  String? get error => _error;
  List<ScannedFile> get outputs => List.unmodifiable(_outputs);
  bool get isOfficeAvailable => services.converter.isOfficeAvailable;
  bool get officeIsDemo => services.converter.isOfficeDemo;
  String get officeNote => services.converter.officeNote;

  /// Whether the current mode accepts more than one file.
  bool get allowsMultiple => switch (_mode) {
    ConversionMode.imagesToPdf => true,
    ConversionMode.officeToPdf => true,
    _ => false,
  };

  List<String> get _allowedExtensions => switch (_mode) {
    ConversionMode.imagesToPdf => FileAccessService.imageExtensions,
    ConversionMode.officeToPdf => const ['doc', 'docx', 'xls', 'xlsx'],
    _ => const ['pdf'],
  };

  void setMode(ConversionMode mode) {
    if (_mode == mode) return;
    _mode = mode;
    _inputs.clear();
    _outputs = [];
    _error = null;
    _progress = null;
    _status = null;
    notifyListeners();
  }

  void setQuality(PdfQuality quality) {
    _quality = quality;
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  Future<void> pickFromDevice() async {
    try {
      final paths = await services.fileAccess.pickFiles(
        allowedExtensions: _allowedExtensions,
        allowMultiple: allowsMultiple,
      );
      if (paths.isEmpty) return;
      _setInputs(allowsMultiple ? paths : [paths.first]);
    } catch (error) {
      _error = 'Could not open the picker: ${_describe(error)}';
      notifyListeners();
    }
  }

  /// Adds a file from the scan history, keeping mode compatibility in mind.
  void useHistoryFile(ScannedFile file) {
    if (!_accepts(file.kind)) {
      _error = '${file.name} cannot be used in ${_mode.label}.';
      notifyListeners();
      return;
    }
    if (_inputs.contains(file.path)) return;
    _setInputs(allowsMultiple ? [..._inputs, file.path] : [file.path]);
  }

  void removeInput(String path) {
    _inputs.remove(path);
    notifyListeners();
  }

  void clear() {
    _inputs.clear();
    _outputs = [];
    _error = null;
    notifyListeners();
  }

  Future<void> convert() async {
    if (_inputs.isEmpty) {
      _error = 'Choose a file to convert.';
      notifyListeners();
      return;
    }
    if (_mode.isOffice && !isOfficeAvailable) {
      _error = officeNote;
      notifyListeners();
      return;
    }

    _busy = true;
    _progress = 0;
    _status = null;
    _error = null;
    _outputs = [];
    notifyListeners();

    try {
      final result = await services.converter.convert(
        mode: _mode,
        inputPaths: List.of(_inputs),
        quality: _quality,
        outputDir: services.directories.exports,
        onProgress: (progress) {
          _progress = progress.fraction;
          _status = progress.label;
          notifyListeners();
        },
      );

      final registered = <ScannedFile>[];
      for (final artifact in result.artifacts) {
        registered.add(
          await services.registerFile(
            path: artifact.path,
            origin: FileOrigin.conversion,
            pageCount: artifact.pageCount,
          ),
        );
      }
      _outputs = registered;
      _progress = 1;
    } catch (error) {
      _error = _describe(error);
    } finally {
      _busy = false;
      _progress = null;
      _status = null;
      notifyListeners();
    }
  }

  /// Keeps the inline result card in sync after a rename.
  void replaceOutput(ScannedFile updated) {
    final index = _outputs.indexWhere((file) => file.id == updated.id);
    if (index < 0) return;
    _outputs[index] = updated;
    notifyListeners();
  }

  /// Dismisses the result card without touching the source selection.
  void dismissResult() {
    if (_outputs.isEmpty) return;
    _outputs = [];
    notifyListeners();
  }

  /// Files from the hub that fit the current mode (rendered newest first).
  List<ScannedFile> historyForMode(List<ScannedFile> files) {
    return files.where((file) => _accepts(file.kind)).toList(growable: false);
  }

  bool _accepts(FileKind kind) => switch (_mode) {
    ConversionMode.imagesToPdf => kind == FileKind.image,
    ConversionMode.officeToPdf =>
      kind == FileKind.document || kind == FileKind.spreadsheet,
    _ => kind == FileKind.pdf,
  };

  void _setInputs(List<String> paths) {
    _inputs
      ..clear()
      ..addAll(paths);
    _outputs = [];
    _error = null;
    notifyListeners();
  }

  String _describe(Object error) {
    final message = error.toString();
    return message.replaceFirst(RegExp(r'^[A-Za-z]+Exception: '), '');
  }
}
