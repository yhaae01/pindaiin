import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models/conversion.dart';
import '../../core/models/scanned_file.dart';
import '../../core/services/file_repository.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/status_views.dart';
import '../files/file_preview_screen.dart';
import 'converter_controller.dart';

/// Converter tab. Images ↔ PDF work fully offline; Office → PDF is routed
/// through a service interface and shows a clear notice until a backend exists.
class ConverterScreen extends StatelessWidget {
  const ConverterScreen({super.key, required this.onOpenFiles});

  final VoidCallback onOpenFiles;

  Future<void> _pickHistory(
    BuildContext context,
    ConverterController controller,
    FileRepository repository,
  ) async {
    final candidates = controller.historyForMode(repository.files);
    final selected = await showModalBottomSheet<ScannedFile>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.55,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text(
                  'From your files',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              Expanded(
                child: candidates.isEmpty
                    ? EmptyState(
                        icon: Icons.history,
                        title: 'Nothing to pick',
                        message:
                            'No files matching ${controller.mode.label} are in '
                            'your history yet.',
                      )
                    : ListView.builder(
                        itemCount: candidates.length,
                        itemBuilder: (context, index) {
                          final file = candidates[index];
                          return ListTile(
                            leading: _FileKindIcon(kind: file.kind),
                            title: Text(
                              file.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${file.kind.label} • ${Formatters.bytes(file.sizeBytes)}',
                            ),
                            onTap: () => Navigator.of(context).pop(file),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected != null) controller.useHistoryFile(selected);
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ConverterController>();
    final repository = context.watch<FileRepository>();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Convert')),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
            children: [
              Text(
                'What do you want to convert?',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: ConversionMode.values
                    .map(
                      (mode) => ChoiceChip(
                        label: Text(mode.label),
                        selected: controller.mode == mode,
                        onSelected: (_) => controller.setMode(mode),
                      ),
                    )
                    .toList(growable: false),
              ),
              const SizedBox(height: 12),
              Text(
                _modeDescription(controller.mode),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (controller.mode.isOffice) ...[
                const SizedBox(height: 16),
                _NoticeCard(
                  icon: controller.officeIsDemo
                      ? Icons.science_outlined
                      : Icons.cloud_done_outlined,
                  message: controller.officeNote,
                ),
              ],
              if (controller.error != null) ...[
                const SizedBox(height: 16),
                ErrorBanner(
                  message: controller.error!,
                  onRetry: controller.clearError,
                ),
              ],
              const SizedBox(height: 20),
              _SectionCard(
                title: 'Source files',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (controller.inputs.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          'No file selected. ${_acceptedHint(controller.mode)}',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      )
                    else
                      ...controller.inputs.map(
                        (path) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          leading: const Icon(Icons.insert_drive_file_outlined),
                          title: Text(
                            path.split('/').last,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            tooltip: 'Remove',
                            icon: const Icon(Icons.close),
                            onPressed: () => controller.removeInput(path),
                          ),
                        ),
                      ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: controller.isBusy
                                ? null
                                : controller.pickFromDevice,
                            icon: const Icon(Icons.folder_open_outlined),
                            label: const Text('Choose files'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: controller.isBusy
                                ? null
                                : () => _pickHistory(context, controller, repository),
                            icon: const Icon(Icons.history),
                            label: const Text('From files'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _SectionCard(
                title: 'Output quality',
                child: Wrap(
                  spacing: 8,
                  children: PdfQuality.values
                      .map(
                        (quality) => ChoiceChip(
                          label: Text(quality.label),
                          selected: controller.quality == quality,
                          onSelected: (_) => controller.setQuality(quality),
                        ),
                      )
                      .toList(growable: false),
                ),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed:
                    controller.inputs.isEmpty ||
                        controller.isBusy ||
                        (controller.mode.isOffice && !controller.isOfficeAvailable)
                    ? null
                    : controller.convert,
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(_actionLabel(controller.mode)),
              ),
              if (controller.outputs.isNotEmpty) ...[
                const SizedBox(height: 20),
                _ResultCard(
                  outputs: controller.outputs,
                  onShare: controller.shareOutputs,
                  onOpenFiles: onOpenFiles,
                  onPreview: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          FilePreviewScreen(file: controller.outputs.first),
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (controller.isBusy)
            BusyOverlay(
              message: controller.statusText ?? 'Converting…',
              progress: controller.progress,
            ),
        ],
      ),
    );
  }
}

String _modeDescription(ConversionMode mode) => switch (mode) {
  ConversionMode.imagesToPdf =>
    'Combine JPG, PNG or WebP images into one PDF. Runs on this device.',
  ConversionMode.pdfToImages =>
    'Render every page of a PDF as a JPG. Runs on this device.',
  ConversionMode.officeToPdf =>
    'Upload DOCX or XLSX and download a rendered PDF. Requires the conversion '
        'service.',
  ConversionMode.pdfToWord =>
    'Upload a PDF and download an editable Word document. Requires the '
        'conversion service.',
  ConversionMode.pdfToExcel =>
    'Upload a PDF and download an Excel workbook. Requires the conversion '
        'service.',
};

String _acceptedHint(ConversionMode mode) => switch (mode) {
  ConversionMode.imagesToPdf => 'Accepts JPG, PNG and WebP.',
  ConversionMode.pdfToImages => 'Choose one PDF.',
  ConversionMode.officeToPdf => 'Accepts DOC, DOCX, XLS and XLSX.',
  ConversionMode.pdfToWord || ConversionMode.pdfToExcel => 'Choose one PDF.',
};

String _actionLabel(ConversionMode mode) => switch (mode) {
  ConversionMode.imagesToPdf => 'Convert to PDF',
  ConversionMode.pdfToImages => 'Convert to images',
  ConversionMode.officeToPdf => 'Convert to PDF',
  ConversionMode.pdfToWord => 'Convert to Word',
  ConversionMode.pdfToExcel => 'Convert to Excel',
};

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: scheme.onSecondaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onSecondaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.outputs,
    required this.onShare,
    required this.onOpenFiles,
    required this.onPreview,
  });

  final List<ScannedFile> outputs;
  final Future<void> Function() onShare;
  final VoidCallback onOpenFiles;
  final VoidCallback onPreview;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.check_circle_outline, color: scheme.onPrimaryContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Created ${outputs.length} file${outputs.length == 1 ? '' : 's'}',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: scheme.onPrimaryContainer,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...outputs.take(4).map(
            (file) => Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                file.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: scheme.onPrimaryContainer),
              ),
            ),
          ),
          if (outputs.length > 4)
            Text(
              '+ ${outputs.length - 4} more',
              style: TextStyle(color: scheme.onPrimaryContainer),
            ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: onPreview,
                icon: const Icon(Icons.visibility_outlined),
                label: const Text('Open'),
              ),
              OutlinedButton.icon(
                onPressed: onShare,
                icon: const Icon(Icons.share_outlined),
                label: const Text('Share'),
              ),
              FilledButton.tonalIcon(
                onPressed: onOpenFiles,
                icon: const Icon(Icons.folder_outlined),
                label: const Text('View in Files'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FileKindIcon extends StatelessWidget {
  const _FileKindIcon({required this.kind});

  final FileKind kind;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CircleAvatar(
      backgroundColor: scheme.surfaceContainerHighest,
      child: Icon(
        switch (kind) {
          FileKind.pdf => Icons.picture_as_pdf_outlined,
          FileKind.image => Icons.image_outlined,
          FileKind.document => Icons.description_outlined,
          FileKind.spreadsheet => Icons.table_chart_outlined,
          FileKind.other => Icons.insert_drive_file_outlined,
        },
        size: 20,
      ),
    );
  }
}
