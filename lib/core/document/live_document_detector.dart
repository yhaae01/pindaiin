import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';

import 'document_corners.dart';
import 'document_detector.dart';
import 'edge_document_detector.dart';
import 'live_scan.dart';
import 'luma_frame.dart';

/// Runs document detection on live camera frames, off the UI thread.
///
/// Design goals:
/// - **Smooth UI:** detection happens in a long-lived worker isolate, so the
///   preview and overlay never block on the heuristic.
/// - **No queue buildup:** at most one frame is in flight and submissions are
///   rate limited ([LiveScanConfig.maxFps]). Frames that arrive while the
///   detector is busy are dropped, not buffered. This is the backpressure that
///   keeps latency bounded on slow devices.
/// - **Testable:** smoothing and stability live in [LiveScanTracker]; this class
///   only owns the isolate, throttling and bookkeeping.
class LiveDocumentDetector extends ChangeNotifier {
  LiveDocumentDetector({this.config = const LiveScanConfig()})
    : _tracker = LiveScanTracker(config: config);

  final LiveScanConfig config;
  final LiveScanTracker _tracker;

  Isolate? _isolate;
  ReceivePort? _receivePort;
  SendPort? _workerPort;
  Completer<SendPort>? _ready;

  bool _inFlight = false;
  bool _disposed = false;
  int _requestId = 0;
  int _pendingQuarterTurns = 0;
  DateTime? _lastSubmitAt;
  DateTime? _inFlightSince;
  Duration? _lastProcessingTime;

  int _droppedFrames = 0;
  int _throttledFrames = 0;
  int _errors = 0;
  double _averageProcessingMs = 0;

  LiveScanUpdate _update = LiveScanUpdate.empty;

  LiveScanUpdate get update => _update;

  bool get isRunning => _workerPort != null;

  /// Cheap preflight used by the camera callback to skip converting frames the
  /// detector would drop anyway (busy or inside the rate-limit window).
  bool get canAcceptFrame {
    if (_disposed || _workerPort == null) return false;
    if (_inFlight) {
      final since = _inFlightSince;
      if (since != null &&
          DateTime.now().difference(since) < const Duration(seconds: 2)) {
        return false;
      }
    }
    final last = _lastSubmitAt;
    return last == null ||
        DateTime.now().difference(last) >= config.minFrameInterval;
  }

  /// Frames dropped because the detector was still working on the previous one.
  int get droppedFrames => _droppedFrames;

  /// Frames skipped by the [LiveScanConfig.maxFps] rate limit.
  int get throttledFrames => _throttledFrames;

  int get errors => _errors;

  double get averageProcessingMs => _averageProcessingMs;

  /// Spawns the worker isolate. Safe to call twice; the second call is a no-op.
  Future<void> start() async {
    if (_disposed || _workerPort != null || _ready != null) return;

    final receive = ReceivePort();
    _receivePort = receive;
    final ready = Completer<SendPort>();
    _ready = ready;
    receive.listen(_onMessage);

    try {
      _isolate = await Isolate.spawn(
        _liveDetectionWorker,
        receive.sendPort,
        debugName: 'live-document-detector',
        errorsAreFatal: false,
      );
      _workerPort = await ready.future.timeout(const Duration(seconds: 5));
    } catch (error) {
      await stop();
      _errors++;
      _update = LiveScanUpdate(
        note: 'Live edge detection could not start: $error',
        processedFrames: _update.processedFrames,
      );
      _notify();
    }
  }

  /// Submits a grayscale frame. [quarterTurns] rotates the detected corners from
  /// the camera frame orientation to what the preview shows.
  ///
  /// Returns false when the frame was throttled or dropped; callers can ignore
  /// this, it exists for tests and diagnostics.
  bool submit(
    LumaFrame frame, {
    required int quarterTurns,
  }) {
    if (_disposed || _workerPort == null || !frame.isValid) return false;

    // Watchdog: a lost worker reply must never block detection forever.
    if (_inFlight &&
        _inFlightSince != null &&
        DateTime.now().difference(_inFlightSince!) >
            const Duration(seconds: 2)) {
      _inFlight = false;
      _errors++;
    }

    if (_inFlight) {
      _droppedFrames++;
      return false;
    }

    final now = DateTime.now();
    final last = _lastSubmitAt;
    if (last != null && now.difference(last) < config.minFrameInterval) {
      _throttledFrames++;
      return false;
    }

    _lastSubmitAt = now;
    _inFlight = true;
    _inFlightSince = now;
    _pendingQuarterTurns = quarterTurns % 4;
    final id = ++_requestId;

    _workerPort!.send(<Object?>[
      id,
      frame.width,
      frame.height,
      config.hullPoints,
      TransferableTypedData.fromList(<TypedData>[frame.bytes]),
    ]);
    return true;
  }

  /// Clears the stability streak, e.g. right after a photo was captured.
  void acknowledgeCapture() {
    _tracker.reset();
    _update = _tracker.current;
    _notify();
  }

  Future<void> stop() async {
    _receivePort?.close();
    _receivePort = null;
    _ready = null;
    _workerPort = null;
    _inFlight = false;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    if (!_disposed) {
      _tracker.reset();
      _update = _tracker.current;
    }
  }

  void _onMessage(Object? message) {
    if (message is SendPort) {
      final ready = _ready;
      if (ready != null && !ready.isCompleted) ready.complete(message);
      return;
    }
    if (message is! List || message.length < 4) return;

    final id = message[0] as int;
    if (id != _requestId || _disposed) return;
    final startedAt = _inFlightSince;
    _inFlight = false;
    _inFlightSince = null;

    final coordinates = message[1];
    final confidence = (message[2] as num?)?.toDouble() ?? 0;
    final note = message[3] as String?;

    DocumentDetection detection;
    if (coordinates is List && coordinates.length == 8) {
      final points = <Offset>[
        for (var index = 0; index < 8; index += 2)
          Offset(
            (coordinates[index] as num).toDouble(),
            (coordinates[index + 1] as num).toDouble(),
          ),
      ];
      detection = DocumentDetection(
        corners: DocumentCorners.fromPoints(points),
        confidence: confidence,
        note: note,
      );
    } else {
      detection = DocumentDetection.unsure(note: note);
    }

    final processing = startedAt == null
        ? _lastProcessingTime
        : DateTime.now().difference(startedAt);
    _lastProcessingTime = processing;
    if (processing != null) {
      final ms = processing.inMicroseconds / 1000;
      _averageProcessingMs = _averageProcessingMs == 0
          ? ms
          : _averageProcessingMs * 0.8 + ms * 0.2;
    }

    _update = _tracker.update(
      detection,
      quarterTurns: _pendingQuarterTurns,
      processingTime: processing,
    );
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _receivePort?.close();
    _receivePort = null;
    _workerPort = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    super.dispose();
  }
}

/// Long-lived worker: receives luminance frames, answers with the detected
/// corners in the raw frame orientation.
void _liveDetectionWorker(SendPort parent) {
  final port = ReceivePort();
  parent.send(port.sendPort);

  port.listen((message) {
    if (message is! List || message.length < 5) return;
    final id = message[0] as int;
    final width = message[1] as int;
    final height = message[2] as int;
    final hullPoints = message[3] as int;
    final transferable = message[4] as TransferableTypedData;

    try {
      final bytes = transferable.materialize().asUint8List();
      final detection = detectDocumentLuminance(
        bytes,
        width: width,
        height: height,
        // Already downsampled by the camera converter.
        analysisSize: width > height ? width : height,
        hullPoints: hullPoints,
      );
      parent.send(<Object?>[
        id,
        <double>[for (final point in detection.corners.points) ...[
          point.dx,
          point.dy,
        ]],
        detection.confidence,
        detection.note,
      ]);
    } catch (error) {
      parent.send(<Object?>[id, null, 0.0, 'Edge detection failed: $error']);
    }
  });
}
