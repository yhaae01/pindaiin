import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/app_services.dart';
import '../../core/widgets/status_views.dart';
import 'batch_editor_screen.dart';
import 'scan_controller.dart';
import 'widgets/page_thumbnail.dart';

/// Entry point for a new scan: capture pages with the camera or import existing
/// photos, then continue to the batch editor.
class ScanSessionScreen extends StatefulWidget {
  const ScanSessionScreen({super.key});

  @override
  State<ScanSessionScreen> createState() => _ScanSessionScreenState();
}

class _ScanSessionScreenState extends State<ScanSessionScreen> {
  late final ScanController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ScanController(services: context.read<AppServices>());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    await action();
    if (!mounted) return;
    final error = _controller.error;
    if (error != null) showSnack(context, error);
  }

  Future<void> _continue() async {
    if (_controller.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BatchEditorScreen(controller: _controller),
      ),
    );
  }

  Future<bool> _confirmDiscard() async {
    if (_controller.isEmpty) return true;
    return confirmDialog(
      context,
      title: 'Discard scan?',
      message: 'The pages in this batch have not been exported yet.',
      confirmLabel: 'Discard',
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: _controller.isEmpty,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final discard = await _confirmDiscard();
        if (!discard || !context.mounted) return;
        Navigator.of(context).pop();
      },
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final pages = _controller.pages;
          return Scaffold(
            appBar: AppBar(
              title: const Text('New scan'),
              actions: [
                if (pages.isNotEmpty)
                  TextButton(
                    onPressed: () async {
                      if (await _confirmDiscard() && mounted) {
                        _controller.clearAll();
                      }
                    },
                    child: const Text('Clear'),
                  ),
              ],
            ),
            body: Stack(
              children: [
                ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
                  children: [
                    _IntroCard(pageCount: pages.length),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: _ActionTile(
                            icon: Icons.photo_camera_outlined,
                            label: 'Capture',
                            hint: 'One photo per page',
                            onTap: _controller.isBusy
                                ? null
                                : () => _run(_controller.addFromCamera),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _ActionTile(
                            icon: Icons.photo_library_outlined,
                            label: 'Gallery',
                            hint: 'Pick several at once',
                            onTap: _controller.isBusy
                                ? null
                                : () => _run(_controller.addFromGallery),
                          ),
                        ),
                      ],
                    ),
                    if (_controller.error != null) ...[
                      const SizedBox(height: 16),
                      ErrorBanner(
                        message: _controller.error!,
                        onRetry: _controller.clearError,
                      ),
                    ],
                    const SizedBox(height: 28),
                    if (pages.isEmpty)
                      _EmptyPagesHint(color: scheme.onSurfaceVariant)
                    else ...[
                      Row(
                        children: [
                          Text(
                            'Pages (${pages.length})',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const Spacer(),
                          Text(
                            'Tap to review and reorder',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        height: 96,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: pages.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 8),
                          itemBuilder: (context, index) => PageThumbnail(
                            page: pages[index],
                            index: index,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                if (_controller.isBusy)
                  BusyOverlay(
                    message: _controller.busyLabel ?? 'Working…',
                    progress: _controller.progress,
                  ),
              ],
            ),
            bottomNavigationBar: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: SafeArea(
                top: false,
                child: FilledButton.icon(
                  onPressed: pages.isEmpty || _controller.isBusy
                      ? null
                      : _continue,
                  icon: const Icon(Icons.tune),
                  label: Text(
                    pages.isEmpty
                        ? 'Add pages to continue'
                        : 'Review ${pages.length} page${pages.length == 1 ? '' : 's'}',
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _IntroCard extends StatelessWidget {
  const _IntroCard({required this.pageCount});

  final int pageCount;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          colors: [
            scheme.primaryContainer,
            scheme.secondaryContainer,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.document_scanner_outlined, size: 40, color: scheme.onPrimaryContainer),
          const SizedBox(height: 12),
          Text(
            pageCount == 0 ? 'Scan a document' : 'Batch ready',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: scheme.onPrimaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Capture pages, then rotate, crop, filter and export as a PDF or '
            'images. Originals never leave your device.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: scheme.onPrimaryContainer.withValues(alpha: 0.85),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.hint,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String hint;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
          child: Column(
            children: [
              Icon(icon, size: 28, color: scheme.primary),
              const SizedBox(height: 8),
              Text(label, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 2),
              Text(
                hint,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyPagesHint extends StatelessWidget {
  const _EmptyPagesHint({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
      child: Column(
        children: [
          Icon(Icons.auto_awesome_motion_outlined, size: 32, color: color),
          const SizedBox(height: 8),
          Text(
            'No pages yet',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Text(
            'Use Capture for each page, or import photos from the gallery.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}
