import 'package:flutter/material.dart';

import '../utils/formatters.dart';

/// Asks for a new file name, preselecting the base name (extension kept).
///
/// Returns null when cancelled. The caller is responsible for applying the
/// rename through `AppServices.renameFile` so sanitizing and collision handling
/// stay in the service layer.
Future<String?> showRenameFileDialog(
  BuildContext context, {
  required String currentName,
}) async {
  final input = TextEditingController(text: currentName);
  input.selection = TextSelection(
    baseOffset: 0,
    extentOffset: Formatters.baseName(currentName).length,
  );

  final name = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Rename file'),
      content: TextField(
        controller: input,
        autofocus: true,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(labelText: 'File name'),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(input.text),
          child: const Text('Rename'),
        ),
      ],
    ),
  );
  input.dispose();

  final trimmed = name?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}
