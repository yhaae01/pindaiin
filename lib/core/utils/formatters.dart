import 'package:intl/intl.dart';

/// Small formatting helpers shared by list tiles, dialogs and generated names.
class Formatters {
  Formatters._();

  static final DateFormat _stamp = DateFormat('yyyyMMdd_HHmmss');
  static final DateFormat _readable = DateFormat('d MMM yyyy, HH:mm');

  static String fileStamp(DateTime time) => _stamp.format(time);

  static String dateTime(DateTime time) => _readable.format(time);

  static String bytes(int size) {
    if (size < 1024) return '$size B';
    final kb = size / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
    final mb = kb / 1024;
    return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
  }

  /// Replaces the extension of [name] with [extension] (without leading dot).
  static String withExtension(String name, String extension) {
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    return '$base.$extension';
  }

  static String baseName(String name) {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }
}
