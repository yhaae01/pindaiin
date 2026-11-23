import 'package:flutter/material.dart';

import '../../../core/models/scan_page.dart';

Future<ScanFilter?> showFilterSheet(
  BuildContext context, {
  required ScanFilter selected,
}) {
  return showModalBottomSheet<ScanFilter>(
    context: context,
    showDragHandle: true,
    builder: (context) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Filter', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                'Applies to the current page. Original pixels are kept; the '
                'filter is baked at export.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              RadioGroup<ScanFilter>(
                groupValue: selected,
                onChanged: (value) {
                  if (value != null) Navigator.of(context).pop(value);
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: ScanFilter.values
                      .map(
                        (filter) => RadioListTile<ScanFilter>(
                          value: filter,
                          title: Text(filter.label),
                          subtitle: Text(_description(filter)),
                          contentPadding: EdgeInsets.zero,
                        ),
                      )
                      .toList(growable: false),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

String _description(ScanFilter filter) => switch (filter) {
  ScanFilter.original => 'No processing',
  ScanFilter.grayscale => 'Removes color, keeps detail',
  ScanFilter.document => 'Grayscale with boosted contrast for text',
};
