import 'package:flutter/material.dart';

import '../../../core/models/conversion.dart';
import '../scan_controller.dart';

class ExportOptions {
  const ExportOptions({
    required this.asPdf,
    required this.quality,
    this.format = ImageExportFormat.jpg,
  });

  final bool asPdf;
  final PdfQuality quality;
  final ImageExportFormat format;
}

Future<ExportOptions?> showExportSheet(
  BuildContext context, {
  required int pageCount,
}) {
  return showModalBottomSheet<ExportOptions>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _ExportSheet(pageCount: pageCount),
  );
}

class _ExportSheet extends StatefulWidget {
  const _ExportSheet({required this.pageCount});

  final int pageCount;

  @override
  State<_ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<_ExportSheet> {
  bool _asPdf = true;
  PdfQuality _quality = PdfQuality.balanced;
  ImageExportFormat _format = ImageExportFormat.jpg;

  void _submit() {
    Navigator.of(context).pop(
      ExportOptions(asPdf: _asPdf, quality: _quality, format: _format),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Export', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              '${widget.pageCount} page${widget.pageCount == 1 ? '' : 's'} '
              'with current rotation, crop and filters.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: true,
                  icon: Icon(Icons.picture_as_pdf_outlined),
                  label: Text('One PDF'),
                ),
                ButtonSegment(
                  value: false,
                  icon: Icon(Icons.image_outlined),
                  label: Text('Images'),
                ),
              ],
              selected: {_asPdf},
              onSelectionChanged: (value) =>
                  setState(() => _asPdf = value.first),
            ),
            if (!_asPdf) ...[
              const SizedBox(height: 12),
              SegmentedButton<ImageExportFormat>(
                segments: const [
                  ButtonSegment(
                    value: ImageExportFormat.jpg,
                    label: Text('JPG'),
                  ),
                  ButtonSegment(
                    value: ImageExportFormat.png,
                    label: Text('PNG'),
                  ),
                ],
                selected: {_format},
                onSelectionChanged: (value) =>
                    setState(() => _format = value.first),
              ),
            ],
            const SizedBox(height: 24),
            Text('Quality', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            RadioGroup<PdfQuality>(
              groupValue: _quality,
              onChanged: (value) =>
                  setState(() => _quality = value ?? _quality),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: PdfQuality.values
                    .map(
                      (quality) => RadioListTile<PdfQuality>(
                        value: quality,
                        title: Text(quality.label),
                        subtitle: Text(quality.description),
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                      ),
                    )
                    .toList(growable: false),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _submit,
              icon: Icon(_asPdf ? Icons.picture_as_pdf : Icons.download),
              label: Text(_asPdf ? 'Save PDF' : 'Save images'),
            ),
          ],
        ),
      ),
    );
  }
}
