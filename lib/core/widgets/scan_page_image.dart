import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/scan_page.dart';

/// Color matrices match the export pipeline in `ImageProcessor` closely enough
/// for a live preview (grayscale luminance, plus a contrast boost for Document).
ColorFilter? colorFilterFor(ScanFilter filter) {
  switch (filter) {
    case ScanFilter.original:
      return null;
    case ScanFilter.grayscale:
      return const ColorFilter.matrix(_grayscale);
    case ScanFilter.document:
      return const ColorFilter.matrix(_document);
  }
}

const List<double> _grayscale = [
  0.2126, 0.7152, 0.0722, 0, 0,
  0.2126, 0.7152, 0.0722, 0, 0,
  0.2126, 0.7152, 0.0722, 0, 0,
  0, 0, 0, 1, 0,
];

// Luminance weights with contrast ~1.45 and a slight lift (offset = 128*(1-c)).
const List<double> _document = [
  0.308, 1.037, 0.105, 0, 0,
  0.308, 1.037, 0.105, 0, 0,
  0.308, 1.037, 0.105, 0, 0,
  0, 0, 0, 1, 0,
];

/// Decodes an image at a bounded resolution (avoids OOM on 50 MP photos).
Future<ui.Image> decodeScanImage(String path, {int targetWidth = 1600}) async {
  final bytes = await File(path).readAsBytes();
  final codec = await ui.instantiateImageCodec(
    bytes,
    targetWidth: targetWidth,
  );
  final frame = await codec.getNextFrame();
  return frame.image;
}

/// Renders a [ScanPage] with its rotation, crop and filter applied, without
/// touching the original file.
class ScanPageImage extends StatefulWidget {
  const ScanPageImage({
    super.key,
    required this.page,
    this.ignoreCrop = false,
    this.preloadedImage,
    this.targetWidth = 1600,
    this.backgroundColor = const Color(0xFF1C1B1F),
  });

  final ScanPage page;

  /// Used by the crop screen, which draws the overlay over the full page.
  final bool ignoreCrop;
  final ui.Image? preloadedImage;
  final int targetWidth;
  final Color backgroundColor;

  @override
  State<ScanPageImage> createState() => _ScanPageImageState();
}

class _ScanPageImageState extends State<ScanPageImage> {
  ui.Image? _image;
  bool _failed = false;
  bool _ownsImage = false;

  @override
  void initState() {
    super.initState();
    if (widget.preloadedImage != null) {
      _image = widget.preloadedImage;
    } else {
      _load();
    }
  }

  @override
  void didUpdateWidget(covariant ScanPageImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.preloadedImage != null) {
      _image = widget.preloadedImage;
      _ownsImage = false;
      return;
    }
    if (oldWidget.page.imagePath != widget.page.imagePath ||
        oldWidget.targetWidth != widget.targetWidth) {
      _disposeOwned();
      _image = null;
      _failed = false;
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final image = await decodeScanImage(
        widget.page.imagePath,
        targetWidth: widget.targetWidth,
      );
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() {
        _image = image;
        _ownsImage = true;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  void _disposeOwned() {
    if (_ownsImage) {
      _image?.dispose();
      _ownsImage = false;
    }
  }

  @override
  void dispose() {
    _disposeOwned();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) {
      return ColoredBox(
        color: widget.backgroundColor,
        child: Center(
          child: _failed
              ? const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.broken_image_outlined, color: Colors.white70),
                    SizedBox(height: 8),
                    Text(
                      'Image unavailable',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ],
                )
              : const CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }

    final crop = widget.ignoreCrop
        ? const Rect.fromLTWH(0, 0, 1, 1)
        : widget.page.crop;
    final sourceSize = Size(image.width.toDouble(), image.height.toDouble());
    final rotated = widget.page.quarterTurns.isOdd
        ? Size(sourceSize.height, sourceSize.width)
        : sourceSize;

    final aspect = (rotated.width * crop.width) / (rotated.height * crop.height);

    return AspectRatio(
      aspectRatio: aspect,
      child: ColoredBox(
        color: widget.backgroundColor,
        child: CustomPaint(
          painter: _ScanPagePainter(
            image: image,
            quarterTurns: widget.page.quarterTurns % 4,
            crop: crop,
            filter: widget.page.filter,
          ),
        ),
      ),
    );
  }
}

class _ScanPagePainter extends CustomPainter {
  _ScanPagePainter({
    required this.image,
    required this.quarterTurns,
    required this.crop,
    required this.filter,
  });

  final ui.Image image;
  final int quarterTurns;
  final Rect crop;
  final ScanFilter filter;

  @override
  void paint(Canvas canvas, Size size) {
    final width = image.width.toDouble();
    final height = image.height.toDouble();

    // Crop in rotated coordinates -> source rectangle (clockwise rotation).
    final cropPx = Rect.fromLTWH(
      crop.left * (quarterTurns.isOdd ? height : width),
      crop.top * (quarterTurns.isOdd ? width : height),
      crop.width * (quarterTurns.isOdd ? height : width),
      crop.height * (quarterTurns.isOdd ? width : height),
    );

    final source = switch (quarterTurns) {
      1 => Rect.fromLTWH(
          cropPx.top,
          height - cropPx.right,
          cropPx.height,
          cropPx.width,
        ),
      2 => Rect.fromLTWH(
          width - cropPx.right,
          height - cropPx.bottom,
          cropPx.width,
          cropPx.height,
        ),
      3 => Rect.fromLTWH(
          width - cropPx.bottom,
          cropPx.left,
          cropPx.height,
          cropPx.width,
        ),
      _ => cropPx,
    };

    // Snap to pixel edges so bilinear sampling never shows a transparent seam.
    final snapped = Rect.fromLTRB(
      source.left.floorToDouble().clamp(0, width),
      source.top.floorToDouble().clamp(0, height),
      source.right.ceilToDouble().clamp(0, width),
      source.bottom.ceilToDouble().clamp(0, height),
    );

    final fitted = applyBoxFit(BoxFit.contain, snapped.size, size);
    final destination = Alignment.center.inscribe(
      fitted.destination,
      Offset.zero & size,
    );

    canvas.drawImageRect(
      image,
      snapped,
      destination,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..colorFilter = colorFilterFor(filter),
    );
  }

  @override
  bool shouldRepaint(covariant _ScanPagePainter oldDelegate) {
    return oldDelegate.image != image ||
        oldDelegate.quarterTurns != quarterTurns ||
        oldDelegate.crop != crop ||
        oldDelegate.filter != filter;
  }
}
