import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart' show ResultType;
import 'package:pdfx/pdfx.dart';
import 'package:provider/provider.dart';

import '../../core/models/scanned_file.dart';
import '../../core/services/app_services.dart';
import '../../core/services/file_access_service.dart';
import '../../core/widgets/status_views.dart';

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
          : switch (file.kind) {
              FileKind.image => InteractiveViewer(
                maxScale: 5,
                child: Center(
                  child: Image.file(
                    File(file.path),
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) =>
                        const EmptyState(
                          icon: Icons.broken_image_outlined,
                          title: 'Cannot preview',
                          message: 'The image file appears to be corrupted.',
                        ),
                  ),
                ),
              ),
              FileKind.pdf => PdfPagesView(path: file.path),
              _ => EmptyState(
                icon: Icons.insert_drive_file_outlined,
                title: 'No preview available',
                message: 'Open this file in another app to view it.',
                action: FilledButton.icon(
                  onPressed: () => _openExternally(context),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open file'),
                ),
              ),
            },
    );
  }
}

class PdfPagesView extends StatefulWidget {
  const PdfPagesView({super.key, required this.path});

  final String path;

  @override
  State<PdfPagesView> createState() => _PdfPagesViewState();
}

class _PdfPagesViewState extends State<PdfPagesView> {
  PdfDocument? _document;
  Uint8List? _bytes;
  int _page = 1;
  int _pageCount = 0;
  bool _loading = true;
  String? _error;
  int _renderToken = 0;

  @override
  void initState() {
    super.initState();
    _open();
  }

  void _retryOpen() {
    setState(() {
      _error = null;
      _loading = true;
    });
    _open();
  }

  Future<void> _open() async {
    try {
      final document = await PdfDocument.openFile(widget.path);
      if (!mounted) {
        await document.close();
        return;
      }
      setState(() {
        _document = document;
        _pageCount = document.pagesCount;
      });
      await _render(1);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = 'Could not open this PDF.';
          _loading = false;
        });
      }
    }
  }

  Future<void> _render(int page) async {
    final document = _document;
    if (document == null) return;
    final token = ++_renderToken;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final pdfPage = await document.getPage(page);
      final width = 1400.0;
      final height = width * pdfPage.height / pdfPage.width;
      final rendered = await pdfPage.render(
        width: width,
        height: height,
        format: PdfPageImageFormat.jpeg,
        quality: 88,
        backgroundColor: '#FFFFFF',
      );
      await pdfPage.close();
      if (!mounted || token != _renderToken) return;
      setState(() {
        _bytes = rendered?.bytes;
        _page = page;
        _loading = false;
        if (rendered == null) _error = 'Page $page could not be rendered.';
      });
    } catch (error) {
      if (!mounted || token != _renderToken) return;
      setState(() {
        _error = 'Page $page could not be rendered.';
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _renderToken++;
    _document?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_document == null) {
      return Center(
        child: _error == null
            ? const CircularProgressIndicator()
            : Padding(
                padding: const EdgeInsets.all(20),
                child: ErrorBanner(message: _error!, onRetry: _retryOpen),
              ),
      );
    }

    return Column(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_bytes != null)
                InteractiveViewer(
                  maxScale: 5,
                  child: Center(child: Image.memory(_bytes!, fit: BoxFit.contain)),
                ),
              if (_loading) const Center(child: CircularProgressIndicator()),
              if (_error != null)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: ErrorBanner(
                      message: _error!,
                      onRetry: () => _render(_page),
                    ),
                  ),
                ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Row(
              children: [
                IconButton.outlined(
                  tooltip: 'Previous page',
                  onPressed: _page <= 1 || _loading
                      ? null
                      : () => _render(_page - 1),
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(
                  child: Text(
                    'Page $_page of $_pageCount',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
                IconButton.outlined(
                  tooltip: 'Next page',
                  onPressed: _page >= _pageCount || _loading
                      ? null
                      : () => _render(_page + 1),
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
