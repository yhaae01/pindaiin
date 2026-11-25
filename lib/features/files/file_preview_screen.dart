import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart' show ResultType;
import 'package:provider/provider.dart';

import '../../core/models/scanned_file.dart';
import '../../core/services/app_services.dart';
import '../../core/services/file_access_service.dart';
import '../../core/widgets/status_views.dart';
import '../pdf/pdf_reader_screen.dart';

/// In-app preview: images render directly, PDFs page by page (pdfx cannot
/// render pages in parallel on Android, so navigation is explicit).
class FilePreviewScreen extends StatelessWidget {
  const FilePreviewScreen({super.key, required this.file});

  final ScannedFile file;

  Future<void> _share(BuildContext context) async {
    try {
      final outcome = await context.read<AppServices>().fileAccess.shareFiles(
        [file.path],
        subject: file.name,
      );
      if (!context.mounted) return;
      if (outcome.hasSkipped) {
        showSnack(
          context,
          'The file is missing or empty, so it could not be shared.',
        );
      }
    } on ShareException catch (error) {
      if (context.mounted) showSnack(context, error.message);
    } catch (error) {
      if (context.mounted) {
        showSnack(context, 'Could not open the share sheet.');
      }
    }
  }

  Future<void> _openExternally(BuildContext context) async {
    final services = context.read<AppServices>();
    final result = await services.fileAccess.openExternally(file.path);
    if (result.type != ResultType.done && context.mounted) {
      showSnack(
        context,
        result.message.isEmpty ? 'No app can open this file.' : result.message,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // PDFs get the full reader (zoom, page navigation, metadata and editing).
    if (file.kind == FileKind.pdf) {
      return PdfReaderScreen(file: file);
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(file.name, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Share',
            onPressed: () => _share(context),
            icon: const Icon(Icons.share_outlined),
          ),
          IconButton(
            tooltip: 'Open with another app',
            onPressed: () => _openExternally(context),
            icon: const Icon(Icons.open_in_new),
          ),
        ],
      ),
      body: !File(file.path).existsSync()
          ? const EmptyState(
              icon: Icons.file_present_outlined,
              title: 'File not found',
              message: 'This file was moved or deleted outside the app.',
            )
          : file.kind == FileKind.image
          ? InteractiveViewer(
              maxScale: 5,
              child: Center(
                child: Image.file(
                  File(file.path),
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) => const EmptyState(
                    icon: Icons.broken_image_outlined,
                    title: 'Cannot preview',
                    message: 'The image file appears to be corrupted.',
                  ),
                ),
              ),
            )
          : EmptyState(
              icon: Icons.insert_drive_file_outlined,
              title: 'No preview available',
              message: 'Open this file in another app to view it.',
              action: FilledButton.icon(
                onPressed: () => _openExternally(context),
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open file'),
              ),
            ),
    );
  }
}


