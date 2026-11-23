import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/models/scan_page.dart';
import '../../core/widgets/crop_overlay.dart';
import '../../core/widgets/scan_page_image.dart';

/// Returns the new normalized crop rect, or null when the user cancels.
class CropScreen extends StatefulWidget {
  const CropScreen({super.key, required this.page});

  final ScanPage page;

  @override
  State<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends State<CropScreen> {
  ui.Image? _image;
  bool _failed = false;
  late Rect _crop;

  static const _fullCrop = Rect.fromLTWH(0, 0, 1, 1);

  @override
  void initState() {
    super.initState();
    _crop = widget.page.crop;
    _load();
  }

  Future<void> _load() async {
    try {
      final image = await decodeScanImage(widget.page.imagePath, targetWidth: 2000);
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() => _image = image);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Adjust crop'),
        actions: [
          IconButton(
            tooltip: 'Reset',
            onPressed: _crop == _fullCrop ? null : () => setState(() => _crop = _fullCrop),
            icon: const Icon(Icons.restart_alt),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(_crop),
            child: const Text('Apply'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _failed
          ? const Center(
              child: Text(
                'Image unavailable',
                style: TextStyle(color: Colors.white70),
              ),
            )
          : image == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: _aspectRatio(image),
                        child: ClipRect(
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ScanPageImage(
                                page: widget.page,
                                preloadedImage: image,
                                ignoreCrop: true,
                                backgroundColor: Colors.black,
                              ),
                              CropOverlay(
                                crop: _crop,
                                onChanged: (rect) => setState(() => _crop = rect),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(24, 0, 24, 20),
                  child: Text(
                    'Drag a corner to resize, or drag inside the frame to move it.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  child: SafeArea(
                    top: false,
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.of(context).pop(),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              minimumSize: const Size(0, 48),
                            ),
                            child: const Text('Cancel'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            onPressed: () => Navigator.of(context).pop(_crop),
                            child: const Text('Apply crop'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  double _aspectRatio(ui.Image image) {
    final width = image.width.toDouble();
    final height = image.height.toDouble();
    return widget.page.quarterTurns.isOdd ? height / width : width / height;
  }
}
