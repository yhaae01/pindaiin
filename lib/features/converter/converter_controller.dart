import 'package:flutter/foundation.dart';

import '../../core/models/conversion.dart';
import '../../core/models/scanned_file.dart';
import '../../core/services/app_services.dart';
import '../../core/services/file_access_service.dart';

/// Drives the converter UI: source selection, mode/quality and the conversion
/// itself. All heavy lifting stays behind [DocumentConverterService].
class ConverterController extends ChangeNotifier {
  ConverterController({required AppServices services}) : _services = services;

  final AppServices _services;

  ConversionMode _mode = ConversionMode.imagesToPdf;
  final List<String> _inputs = [];
  PdfQuality _quality = PdfQuality.balanced;
  bool _busy = false;
  double? _progress;
  String? _error;
  List<ScannedFile> _outputs = [];

  ConversionMode get mode => _mode;
  List<String> get inputs => List.unmodifiable(_inputs);
  PdfQuality get quality => _quality;
  bool get isBusy => _busy;
  double? get progress => _progress;
  String? get error => _error;
  List<ScannedFile> get outputs => List.unmodifiable(_outputs);
  bool get isOfficeAvailable => _services.converter.isOfficeAvailable;
  String get officeNote => _services.converter.officeNote;

  /// Whether the current mode accepts more than one file.
  bool get allowsMultiple => _mode != ConversionMode.pdfToImages;

  List<String> get _allowedExtensions => switch (_mode) {
    ConversionMode.imagesToPdf => FileAccessService.imageExtensions,
    ConversionMode.pdfToImages => const ['pdf'],
    ConversionMode.officeToPdf => const ['doc', 'docx', 'xls', 'xlsx'],
  };

  void setMode(ConversionMode mode) {
    if (_mode == mode) return;
    _mode = mode;
    _inputs.clear();
    _outputs = [];
    _error = null;
    _progress = null;
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
      final paths = await _services.fileAccess.pickFiles(
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
    if (_mode == ConversionMode.officeToPdf && !isOfficeAvailable) {
      _error = officeNote;
      notifyListeners();
      return;
    }

    _busy = true;
    _progress = 0;
    _error = null;
    _outputs = [];
    notifyListeners();

    try {
      final result = await _services.converter.convert(
        mode: _mode,
        inputPaths: List.of(_inputs),
        quality: _quality,
        outputDir: _services.directories.exports,
        onProgress: (value) {
          _progress = value;
          notifyListeners();
        },
      );

      final registered = <ScannedFile>[];
      for (final artifact in result.artifacts) {
        registered.add(
          await _services.registerFile(
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
      notifyListeners();
    }
  }

  Future<void> shareOutputs() async {
    if (_outputs.isEmpty) return;
    await _services.fileAccess.shareFiles(
      _outputs.map((file) => file.path).toList(growable: false),
      subject: _outputs.first.name,
    );
  }

  /// Files from the hub that fit the current mode (rendered newest first).
  List<ScannedFile> historyForMode(List<ScannedFile> files) {
    return files.where((file) => _accepts(file.kind)).toList(growable: false);
  }

  bool _accepts(FileKind kind) => switch (_mode) {
    ConversionMode.imagesToPdf => kind == FileKind.image,
    ConversionMode.pdfToImages => kind == FileKind.pdf,
    ConversionMode.officeToPdf =>
      kind == FileKind.document || kind == FileKind.spreadsheet,
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
