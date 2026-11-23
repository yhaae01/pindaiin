import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

/// Wraps the platform intents (camera, gallery, SAF picker, share sheet, open
/// with) so features stay free of plugin-specific code and easy to test.
class FileAccessService {
  FileAccessService({ImagePicker? picker}) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  static const imageExtensions = ['jpg', 'jpeg', 'png', 'webp'];

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
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: allowMultiple,
      type: allowedExtensions == null ? FileType.any : FileType.custom,
      allowedExtensions: allowedExtensions,
      withData: false,
    );
    if (result == null) return const [];
    return result.files.map((file) => file.path).whereType<String>().toList();
  }

  Future<void> shareFiles(List<String> paths, {String? subject}) async {
    if (paths.isEmpty) return;
    await SharePlus.instance.share(
      ShareParams(
        files: paths.map(XFile.new).toList(growable: false),
        subject: subject,
      ),
    );
  }

  Future<OpenResult> openExternally(String path) => OpenFilex.open(path);
}
