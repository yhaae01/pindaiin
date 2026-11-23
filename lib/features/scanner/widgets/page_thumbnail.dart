import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/models/scan_page.dart';
import '../../../core/widgets/scan_page_image.dart';

/// Fast thumbnail used in the batch strip. It ignores the crop rect (cheap to
/// render) but keeps rotation and filter so the strip matches the preview.
class PageThumbnail extends StatelessWidget {
  const PageThumbnail({
    super.key,
    required this.page,
    required this.index,
    this.selected = false,
    this.onTap,
    this.width = 64,
    this.height = 84,
  });

  final ScanPage page;
  final int index;
  final bool selected;
  final VoidCallback? onTap;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final filter = colorFilterFor(page.filter);

    Widget image = Image.file(
      File(page.imagePath),
      fit: BoxFit.cover,
      cacheWidth: (width * 3).round(),
      errorBuilder: (context, error, stackTrace) => ColoredBox(
        color: scheme.surfaceContainerHighest,
        child: const Icon(Icons.broken_image_outlined, size: 20),
      ),
    );
    if (filter != null) {
      image = ColorFiltered(colorFilter: filter, child: image);
    }

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? scheme.primary : Colors.transparent,
            width: 2.5,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Stack(
            children: [
              SizedBox(
                width: width,
                height: height,
                child: RotatedBox(
                  quarterTurns: page.quarterTurns,
                  child: image,
                ),
              ),
              Positioned(
                left: 4,
                bottom: 4,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '${index + 1}',
                    style: const TextStyle(color: Colors.white, fontSize: 10),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
