import 'dart:ui';

import 'document_corners.dart';
import 'document_detector.dart';

/// Tunables for live preview detection.
///
/// The defaults keep the analysis cheap enough for mid-range phones: a ~400 px
/// frame at 6 fps is a few percent of a core and leaves headroom for the camera
/// preview, which matters for Android thermal throttling.
class LiveScanConfig {
  const LiveScanConfig({
    this.analysisSize = 400,
    this.maxFps = 6,
    this.hullPoints = 36,
    this.minConfidence = 0.55,
    this.minimumArea = 0.1,
    this.stableFrames = 4,
    this.stableTolerance = 0.02,
    this.smoothing = 0.45,
    this.holdMissedFrames = 2,
    this.autoCaptureCooldown = const Duration(milliseconds: 1200),
  });

  /// Longest edge of the grayscale frame handed to the detector.
  final int analysisSize;

  /// Upper bound on analysis frames per second. Frames arriving faster are
  /// dropped instead of queued.
  final int maxFps;

  /// Hull vertices sampled for the largest-quad fit. Lower is cheaper.
  final int hullPoints;

  /// Minimum detector confidence before the quad is shown as solid.
  final double minConfidence;

  /// Smallest normalized quad area considered a page (not a bright object).
  final double minimumArea;

  /// Consecutive stable frames required before auto-capture arms.
  final int stableFrames;

  /// Max per-corner movement (normalized) that still counts as "stable".
  final double stableTolerance;

  /// How much of the previous quad to keep when smoothing (0 = none).
  final double smoothing;

  /// Frames with no confident page that keep the last quad on screen before it
  /// fades out. Prevents flicker on glare or motion blur.
  final int holdMissedFrames;

  /// Minimum time between automatic captures.
  final Duration autoCaptureCooldown;

  Duration get minFrameInterval =>
      Duration(microseconds: (1000000 / maxFps).round());
}

/// Latest live-scan state for the overlay and the auto-capture logic.
class LiveScanUpdate {
  const LiveScanUpdate({
    this.corners,
    this.confidence = 0,
    this.stable = false,
    this.stability = 0,
    this.note,
    this.processedFrames = 0,
    this.processingTime,
  });

  static const LiveScanUpdate empty = LiveScanUpdate();

  /// Smoothed page corners in the displayed (rotated) orientation, or null when
  /// no page is currently visible.
  final DocumentCorners? corners;

  /// 0..1 detector confidence for the latest frame.
  final double confidence;

  /// True after [LiveScanConfig.stableFrames] consistent frames.
  final bool stable;

  /// 0..1 progress towards [stable]; useful for a stability indicator.
  final double stability;

  /// Human readable hint from the detector (e.g. why it fell back).
  final String? note;

  final int processedFrames;
  final Duration? processingTime;

  bool get hasDocument => corners != null;

  bool get isConfident => hasDocument && confidence >= 0.55;

  LiveScanUpdate copyWith({
    DocumentCorners? corners,
    double? confidence,
    bool? stable,
    double? stability,
    String? note,
    int? processedFrames,
    Duration? processingTime,
  }) {
    return LiveScanUpdate(
      corners: corners ?? this.corners,
      confidence: confidence ?? this.confidence,
      stable: stable ?? this.stable,
      stability: stability ?? this.stability,
      note: note ?? this.note,
      processedFrames: processedFrames ?? this.processedFrames,
      processingTime: processingTime ?? this.processingTime,
    );
  }
}

/// Turns raw per-frame detections into a smoothed, stable quad.
///
/// Pure Dart (no camera, no widgets) so it is easy to unit test. Corner smoothing
/// removes the jitter of heuristic edge detection; the stability streak is what
/// auto-capture waits for, so a page is never captured while the phone is moving.
class LiveScanTracker {
  LiveScanTracker({required this.config});

  final LiveScanConfig config;

  DocumentCorners? _smoothed;
  DocumentCorners? _lastDisplayed;
  int _stableStreak = 0;
  int _missedFrames = 0;
  int _processedFrames = 0;

  LiveScanUpdate get current => _last;
  LiveScanUpdate _last = LiveScanUpdate.empty;

  LiveScanUpdate update(
    DocumentDetection detection, {
    required int quarterTurns,
    Duration? processingTime,
  }) {
    _processedFrames++;
    final corners = detection.corners;
    final usable =
        detection.isConfident &&
        corners.isValid &&
        corners.area >= config.minimumArea;

    if (!usable) {
      _stableStreak = 0;
      _lastDisplayed = null;
      _missedFrames++;
      if (_missedFrames > config.holdMissedFrames) {
        _smoothed = null;
      }
      _last = LiveScanUpdate(
        corners: _smoothed,
        confidence: detection.confidence,
        note: detection.note,
        processedFrames: _processedFrames,
        processingTime: processingTime,
      );
      return _last;
    }

    _missedFrames = 0;
    final display = corners.rotated(quarterTurns);
    final previous = _smoothed;
    final next = previous == null
        ? display
        : _blend(previous, display, config.smoothing);

    // Only accept a smoothed quad that is still a sane page; a strong detection
    // should never be made invalid by averaging.
    _smoothed = next.isValid ? next : display;

    // Stability compares raw detections, not the smoothed quad: smoothing must
    // not make a slowly moving page look still enough for auto-capture.
    final previousDisplayed = _lastDisplayed;
    _lastDisplayed = display;
    final moved = previousDisplayed == null
        ? double.infinity
        : _maxCornerDistance(previousDisplayed, display);
    if (moved <= config.stableTolerance) {
      _stableStreak++;
    } else {
      _stableStreak = 0;
    }

    final stability = (_stableStreak / config.stableFrames).clamp(0.0, 1.0);
    _last = LiveScanUpdate(
      corners: _smoothed,
      confidence: detection.confidence,
      stable: _stableStreak >= config.stableFrames,
      stability: stability,
      note: detection.note,
      processedFrames: _processedFrames,
      processingTime: processingTime,
    );
    return _last;
  }

  /// Clears the stability streak (after a capture) so the next stable quad has
  /// to be re-earned.
  void reset() {
    _smoothed = null;
    _lastDisplayed = null;
    _stableStreak = 0;
    _missedFrames = 0;
    _last = LiveScanUpdate(
      processedFrames: _processedFrames,
    );
  }

  static DocumentCorners _blend(
    DocumentCorners previous,
    DocumentCorners current,
    double keepPrevious,
  ) {
    Offset mix(Offset a, Offset b) {
      final t = keepPrevious.clamp(0.0, 0.95);
      return Offset(a.dx * t + b.dx * (1 - t), a.dy * t + b.dy * (1 - t));
    }

    return DocumentCorners(
      topLeft: mix(previous.topLeft, current.topLeft),
      topRight: mix(previous.topRight, current.topRight),
      bottomRight: mix(previous.bottomRight, current.bottomRight),
      bottomLeft: mix(previous.bottomLeft, current.bottomLeft),
    );
  }

  static double _maxCornerDistance(DocumentCorners a, DocumentCorners b) {
    var max = 0.0;
    for (var index = 0; index < 4; index++) {
      final distance = (a.points[index] - b.points[index]).distance;
      if (distance > max) max = distance;
    }
    return max;
  }
}
