import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart' show ResultType;
import 'package:provider/provider.dart';

import '../../core/models/scanned_file.dart';
import '../../core/services/app_services.dart';
import '../../core/services/file_access_service.dart';
import '../../core/services/pdf_service.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/status_views.dart';
import 'pdf_editor_screen.dart';

/// Full PDF reader: bounded-memory page rendering, zoom, page navigation,
/// document information and the usual share/open/edit actions.
class PdfReaderScreen extends StatefulWidget {
  const PdfReaderScreen({super.key, required this.file, this.password});

  final ScannedFile file;
  final String? password;

  @override
  State<PdfReaderScreen> createState() => _PdfReaderScreenState();
}

class _PdfReaderScreenState extends State<PdfReaderScreen> {
  final PageController _controller = PageController();
  final Map<int, Uint8List> _images = {};
  final Set<int> _rendering = {};
  final TextEditingController _passwordInput = TextEditingController();

  PdfSession? _session;
  PdfFileInfo? _info;
  String? _password;
  PdfFailure? _failure;
  bool _loading = true;
  int _page = 0;
  Future<void> _renderQueue = Future.value();

  @override
  void initState() {
    super.initState();
    _password = widget.password;
    _open();
  }

  @override
  void dispose() {
    _controller.dispose();
    _passwordInput.dispose();
    _session?.close();
    super.dispose();
  }

  Future<void> _open({String? password}) async {
    final services = context.read<AppServices>();
    await _session?.close();
    _session = null;
    _images.clear();
    _rendering.clear();
    if (password != null) _password = password;

    setState(() {
      _loading = true;
      _failure = null;
    });

    try {
      final session = await services.pdfEditor.open(
        widget.file.path,
        password: _password,
      );
      if (!mounted) {
        await session.close();
        return;
      }
      final info = await services.pdfEditor.fileInfo(widget.file.path, session);
      if (!mounted) {
        await session.close();
        return;
      }
      setState(() {
        _session = session;
        _info = info;
        _loading = false;
        _page = 0;
      });
      _enqueue(0);
      _enqueue(1);
    } on PdfFailure catch (failure) {
      if (mounted) {
        setState(() {
          _failure = failure;
          _loading = false;
        });
      }
    }
  }

  Future<void> _reload() async {
    final page = _page;
    await _open();
    if (!mounted) return;
    if (page > 0 && _session != null) _jumpTo(page);
  }

  void _enqueue(int index, {bool prefetch = false}) {
    final session = _session;
    if (session == null) return;
    if (index < 0 || index >= session.pageCount) return;
    if (_images.containsKey(index) || _rendering.contains(index)) return;
    _rendering.add(index);
    if (!prefetch && index == _page) setState(() {});

    _renderQueue = _renderQueue.then((_) async {
      try {
        final bytes = await session.render(index, maxWidth: 1600);
        if (!mounted || _session != session) return;
        setState(() {
          _images[index] = bytes;
          _rendering.remove(index);
          _evictCache();
        });
      } on PdfFailure catch (failure) {
        if (!mounted || _session != session) return;
        _rendering.remove(index);
        setState(() => _failure = failure);
      } catch (_) {
        if (!mounted || _session != session) return;
        _rendering.remove(index);
        setState(
          () => _failure = const PdfFailure(
            'This page could not be rendered.',
          ),
        );
      }
    });
  }

  void _evictCache() {
    if (_images.length <= 5) return;
    final keep = {_page, _page - 1, _page + 1, _page - 2, _page + 2};
    final removable = _images.keys.where((key) => !keep.contains(key)).toList();
    for (final key in removable) {
      if (_images.length <= 5) break;
      _images.remove(key);
    }
  }

  void _onPageChanged(int index) {
    setState(() => _page = index);
    _enqueue(index);
    _enqueue(index - 1, prefetch: true);
    _enqueue(index + 1, prefetch: true);
  }

  void _jumpTo(int index) {
    if (_session == null) return;
    final page = index.clamp(0, _session!.pageCount - 1);
    if (_controller.hasClients) {
      _controller.animateToPage(
        page,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
    setState(() => _page = page);
    _enqueue(page);
  }

  Future<void> _share() async {
    try {
      final outcome = await context.read<AppServices>().fileAccess.shareFiles(
        [widget.file.path],
        subject: widget.file.name,
      );
      if (!mounted) return;
      if (outcome.hasSkipped) {
        showSnack(context, 'The PDF is missing or empty.');
      }
    } on ShareException catch (error) {
      if (mounted) showSnack(context, error.message);
    } catch (_) {
      if (mounted) showSnack(context, 'Could not open the share sheet.');
    }
  }

  Future<void> _openExternally() async {
    final result = await context
        .read<AppServices>()
        .fileAccess
        .openExternally(widget.file.path);
    if (result.type != ResultType.done && mounted) {
      showSnack(
        context,
        result.message.isEmpty ? 'No app can open this PDF.' : result.message,
      );
    }
  }

  Future<void> _openEditor() async {
    final session = _session;
    if (session == null) return;
    final overwritten = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => PdfEditorScreen(
          file: widget.file,
          password: _password,
        ),
      ),
    );
    if (overwritten == true && mounted) _reload();
  }

  void _showInfo() {
    final info = _info;
    if (info == null) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                info.metadata.title?.trim().isNotEmpty == true
                    ? info.metadata.title!
                    : info.name,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              _InfoRow(label: 'File', value: info.name),
              _InfoRow(label: 'Size', value: Formatters.bytes(info.sizeBytes)),
              _InfoRow(label: 'Pages', value: '${info.pageCount}'),
              _InfoRow(label: 'PDF version', value: info.version),
              _InfoRow(
                label: 'Modified',
                value: Formatters.dateTime(info.modifiedOnDisk),
              ),
              if (info.metadata.author?.trim().isNotEmpty == true)
                _InfoRow(label: 'Author', value: info.metadata.author!),
              if (info.metadata.subject?.trim().isNotEmpty == true)
                _InfoRow(label: 'Subject', value: info.metadata.subject!),
              if (info.metadata.keywords?.trim().isNotEmpty == true)
                _InfoRow(label: 'Keywords', value: info.metadata.keywords!),
              _InfoRow(
                label: 'Protection',
                value: info.isEncrypted ? 'Encrypted PDF' : 'None',
              ),
              _InfoRow(
                label: 'Tagged',
                value: info.isTagged ? 'Yes (accessible)' : 'No',
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                      _share();
                    },
                    icon: const Icon(Icons.share_outlined),
                    label: const Text('Share'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                      _openExternally();
                    },
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('Open'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pageCount = _session?.pageCount ?? 0;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.file.name, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'File information',
            onPressed: _info == null ? null : _showInfo,
            icon: const Icon(Icons.info_outline),
          ),
          IconButton(
            tooltip: 'Share',
            onPressed: _session == null ? null : _share,
            icon: const Icon(Icons.share_outlined),
          ),
          IconButton(
            tooltip: 'Open with another app',
            onPressed: _openExternally,
            icon: const Icon(Icons.open_in_new),
          ),
          IconButton(
            tooltip: 'Edit PDF',
            onPressed: _session == null ? null : _openEditor,
            icon: const Icon(Icons.edit_outlined),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _failure != null && _failure!.kind == PdfFailureKind.passwordRequired
          ? _PasswordPrompt(
              controller: _passwordInput,
              message: _failure!.message,
              onUnlock: () => _open(password: _passwordInput.text),
            )
          : _failure != null && _failure!.kind == PdfFailureKind.wrongPassword
          ? _PasswordPrompt(
              controller: _passwordInput,
              message: _failure!.message,
              onUnlock: () => _open(password: _passwordInput.text),
            )
          : _failure != null || _session == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: ErrorBanner(
                  message:
                      _failure?.message ?? 'The PDF could not be opened.',
                  onRetry: _open,
                ),
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: PageView.builder(
                    controller: _controller,
                    itemCount: pageCount,
                    onPageChanged: _onPageChanged,
                    itemBuilder: (context, index) {
                      final bytes = _images[index];
                      if (bytes == null) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      return InteractiveViewer(
                        maxScale: 4,
                        panEnabled: false,
                        child: Center(
                          child: Image.memory(
                            bytes,
                            fit: BoxFit.contain,
                            gaplessPlayback: true,
                          ),
                        ),
                      );
                    },
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (pageCount > 1)
                          Slider(
                            value: (_page + 1).toDouble(),
                            min: 1,
                            max: pageCount.toDouble(),
                            divisions: pageCount > 1 ? pageCount - 1 : null,
                            label: 'Page ${_page + 1}',
                            onChanged: (value) =>
                                setState(() => _page = value.round() - 1),
                            onChangeEnd: (value) =>
                                _jumpTo(value.round() - 1),
                          ),
                        Row(
                          children: [
                            IconButton.outlined(
                              tooltip: 'Previous page',
                              onPressed: _page <= 0
                                  ? null
                                  : () => _jumpTo(_page - 1),
                              icon: const Icon(Icons.chevron_left),
                            ),
                            Expanded(
                              child: Column(
                                children: [
                                  Text(
                                    'Page ${_page + 1} of $pageCount',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.labelLarge,
                                  ),
                                  if (_images[_page] == null)
                                    const Padding(
                                      padding: EdgeInsets.only(top: 4),
                                      child: SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            IconButton.outlined(
                              tooltip: 'Next page',
                              onPressed: _page >= pageCount - 1
                                  ? null
                                  : () => _jumpTo(_page + 1),
                              icon: const Icon(Icons.chevron_right),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _PasswordPrompt extends StatelessWidget {
  const _PasswordPrompt({
    required this.controller,
    required this.message,
    required this.onUnlock,
  });

  final TextEditingController controller;
  final String message;
  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.lock_outline,
              size: 52,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              'Password required',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 20),
            TextField(
              controller: controller,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'PDF password'),
              onSubmitted: (_) => onUnlock(),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onUnlock,
              icon: const Icon(Icons.lock_open),
              label: const Text('Unlock PDF'),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
