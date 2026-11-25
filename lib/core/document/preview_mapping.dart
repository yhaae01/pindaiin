import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/services.dart' show DeviceOrientation;

import 'document_corners.dart';

/// Maps normalized corners from the camera frame to the preview viewport.
///
/// Camera frames arrive in the sensor orientation (usually landscape) while the
/// preview is shown upright for the current device rotation. The preview uses
/// [BoxFit.cover], so the image is scaled up until it fills the viewport and the
/// overflow is cropped symmetrically. This class reproduces that exact layout
/// for the overlay, which is why the quad sits on the paper at any rotation or
/// screen size.
class PreviewViewportMapping {
  const PreviewViewportMapping({
    required this.frameSize,
    required this.quarterTurns,
    required this.viewport,
  });

  /// Raw frame size (sensor orientation), e.g. 1280 × 720.
  final Size frameSize;

  /// Clockwise quarter turns applied to the frame for display.
  final int quarterTurns;

  final Size viewport;

  /// Frame size after [quarterTurns], i.e. the orientation the user sees.
  Size get naturalSize => quarterTurns.isOdd
      ? Size(frameSize.height, frameSize.width)
      : frameSize;

  /// The rect the camera image occupies inside [viewport] with `BoxFit.cover`.
  Rect get displayRect {
    final natural = naturalSize;
    if (natural.width <= 0 ||
        natural.height <= 0 ||
        viewport.width <= 0 ||
        viewport.height <= 0) {
      return Offset.zero & viewport;
    }
    final scale = math.max(
      viewport.width / natural.width,
      viewport.height / natural.height,
    );
    final width = natural.width * scale;
    final height = natural.height * scale;
    return Rect.fromLTWH(
      (viewport.width - width) / 2,
      (viewport.height - height) / 2,
      width,
      height,
    );
  }

  /// Maps a normalized point in the *displayed* (rotated) frame to viewport
  /// pixels.
  Offset map(Offset normalized) {
    final rect = displayRect;
    return Offset(
      rect.left + normalized.dx * rect.width,
      rect.top + normalized.dy * rect.height,
    );
  }

  List<Offset> mapCorners(DocumentCorners corners) =>
      corners.points.map(map).toList(growable: false);
}

/// Clockwise quarter turns needed to bring a camera frame upright in the
/// current device orientation.
///
/// [sensorOrientation] is `CameraDescription.sensorOrientation` (degrees the
/// sensor is rotated relative to the device's natural orientation, 90 for most
/// phones). [deviceOrientation] is the value reported by the camera controller.
/// Detected corners rotate with the same value, so the overlay stays aligned
/// when the phone is turned.
int previewQuarterTurns({
  required int sensorOrientation,
  required DeviceOrientation deviceOrientation,
}) {
  final displayDegrees = switch (deviceOrientation) {
    DeviceOrientation.portraitUp => 0,
    DeviceOrientation.landscapeLeft => 90,
    DeviceOrientation.portraitDown => 180,
    DeviceOrientation.landscapeRight => 270,
  };
  final rotation = (sensorOrientation - displayDegrees + 360) % 360;
  return (rotation ~/ 90) % 4;
}
