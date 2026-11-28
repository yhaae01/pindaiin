import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../../core/document/document_corners.dart';
import '../../../core/document/live_document_detector.dart';
import '../../../core/document/live_scan.dart';
import '../../../core/document/preview_mapping.dart';
import '../../../core/services/app_services.dart';
import '../scan_controller.dart';
import 'camera_frame.dart';

/// Owns the live scanning session: camera lifecycle, the frame stream, edge
/// detection, auto-capture and adding pages to the batch.
///
/// The widget layer only reads state and calls intent methods ([capture],
/// [toggleTorch], [setAutoCapture]); it never touches the camera plugin or the
/// detector. Frame analysis is throttled and never queued (see
/// [LiveDocumentDetector]), so the preview stays responsive on Android devices
/// that thermally throttle.
class LiveScanController extends ChangeNotifier with WidgetsBindingObserver {
  LiveScanController({
    required this.services,
    required this.batch,
    this.config = const LiveScanConfig(),
  }) {
    WidgetsBinding.instance.addObserver(this);
  }

  final AppServices services;
  final ScanController batch;
  final LiveScanConfig config;

  CameraController? _camera;
  LiveDocumentDetector? _detector;

  bool _initializing = false;
  bool _cameraReady = false;
  bool _capturing = false;
  bool _streaming = false;
  bool _paused = false;
  bool _inactive = false;
  bool _autoCapture = false;
  bool _autoArmed = true;
  bool _torch = false;
  bool _disposed = false;

  String? _error;
  String? _warning;
  String? _lastCaptureError;
  Size? _frameSize;
  LiveScanUpdate _update = LiveScanUpdate.empty;
  CapturedPageResult? _lastCapture;
  DocumentCorners? _lastCapturedCorners;
  DateTime? _lastCaptureAt;
  int _capturedCount = 0;

  /// Called after a page was successfully added to the batch.
  ValueChanged<CapturedPageResult>? onPageAdded;

  bool get isInitializing => _initializing;
  bool get isReady => _cameraReady && (_camera?.value.isInitialized ?? false);
  bool get isCapturing => _capturing;
  bool get autoCapture => _autoCapture;
  bool get torchOn => _torch;
  bool get isStreaming => _streaming;
  bool get isPaused => _paused;
  String? get error => _error;
  String? get warning => _warning;
  String? get lastCaptureError => _lastCaptureError;
  LiveScanUpdate get update => _update;
  CapturedPageResult? get lastCapture => _lastCapture;
  int get capturedCount => _capturedCount;
  CameraController? get camera => _camera;
  LiveDocumentDetector? get detector => _detector;

  /// Raw frame size used for overlay mapping. Falls back to the preview size
  /// before the first analysis frame arrives.
  Size get frameSize {
    final cached = _frameSize;
    if (cached != null) return cached;
    final preview = _camera?.value.previewSize;
    if (preview != null && preview.width > 0 && preview.height > 0) {
      return preview;
    }
    return const Size(4, 3);
  }

  /// Clockwise quarter turns from the sensor frame to the displayed preview.
  int get quarterTurns {
    final camera = _camera;
    if (camera == null) return 0;
    return previewQuarterTurns(
      sensorOrientation: camera.description.sensorOrientation,
      deviceOrientation: camera.value.deviceOrientation,
    );
  }

  /// Opens the back camera and starts the analysis stream.
  Future<void> initialize() async {
    if (_disposed || _initializing) return;

    if (_camera != null && _camera!.value.isInitialized) {
      await _startStream();
      return;
    }

    _initializing = true;
    _error = null;
    _warning = null;
    _notify();

    await _releaseCamera();

    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw CameraException('NoCamera', 'No camera is available.');
      }
      final description = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        description,
        ResolutionPreset.veryHigh,
        enableAudio: false,
        imageFormatGroup: defaultTargetPlatform == TargetPlatform.iOS
            ? ImageFormatGroup.bgra8888
            : ImageFormatGroup.yuv420,
      );
      try {
        await controller.initialize();
      } catch (_) {
        await controller.dispose();
        rethrow;
      }
      if (_disposed) {
        await controller.dispose();
        return;
      }

      controller.addListener(_onCameraChanged);
      _camera = controller;
      _cameraReady = true;

      final detector = LiveDocumentDetector(config: config);
      detector.addListener(_onDetection);
      _detector = detector;
      await detector.start();
      if (!detector.isRunning) {
        _warning =
            'Live edge detection is unavailable; manual capture still works.';
      }

      await _startStream();
    } on CameraException catch (error) {
      _error = _cameraErrorMessage(error);
    } catch (error) {
      _error = 'The camera could not be opened: $error';
    } finally {
      _initializing = false;
      if (!_disposed) _notify();
    }
  }

  /// Pauses analysis while the edge editor is open (camera stays initialized).
  Future<void> pause() async {
    if (_paused) return;
    _paused = true;
    await _stopStream();
    _notify();
  }

  Future<void> resume() async {
    if (!_paused) return;
    _paused = false;
    await _startStream();
    _notify();
  }

  void setAutoCapture(bool enabled) {
    if (_autoCapture == enabled) return;
    _autoCapture = enabled;
    _autoArmed = true;
    _notify();
  }

  Future<void> toggleTorch() async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) return;
    final next = _torch ? FlashMode.off : FlashMode.torch;
    try {
      await camera.setFlashMode(next);
      _torch = !_torch;
      _notify();
    } on CameraException catch (error) {
      _lastCaptureError =
          error.description ?? 'The flashlight is not available.';
      _notify();
    }
  }

  /// Takes a high-resolution photo (the preview stream is stopped first, which
  /// is what lets devices that share the sensor stream capture at full quality)
  /// and adds the uncropped page to the batch for edge review.
  Future<CapturedPageResult?> capture() async {
    final camera = _camera;
    if (_disposed ||
        _capturing ||
        camera == null ||
        !camera.value.isInitialized) {
      return null;
    }

    _capturing = true;
    _lastCaptureError = null;
    _notify();

    final detectedCorners = _update.corners;
    try {
      await _stopStream();
      final photo = await camera.takePicture();
      final result = await batch.addCapturedPhoto(photo.path);
      await services.storage.deleteQuietly(photo.path);

      if (result == null) {
        _lastCaptureError = batch.error ?? 'The photo could not be added.';
      } else {
        _lastCapture = result;
        _lastCapturedCorners = detectedCorners;
        _lastCaptureAt = DateTime.now();
        _autoArmed = false;
        _capturedCount++;
        _detector?.acknowledgeCapture();
        onPageAdded?.call(result);
      }
      return result;
    } on CameraException catch (error) {
      _lastCaptureError =
          error.description ?? 'Capture failed (${error.code}).';
    } catch (error) {
      _lastCaptureError = 'Capture failed: $error';
    } finally {
      _capturing = false;
      if (!_disposed) {
        await _startStream();
        _notify();
      }
    }
    return null;
  }

  void clearLastCapture() {
    _lastCapture = null;
    _lastCaptureError = null;
    _notify();
  }

  void _onFrame(CameraImage image) {
    final detector = _detector;
    if (detector == null || _capturing || _paused || _disposed) return;
    _frameSize ??= Size(image.width.toDouble(), image.height.toDouble());
    // Preflight in the stream callback: don't resample a frame that would be
    // dropped for backpressure or throttling. This keeps the UI thread free.
    if (!detector.canAcceptFrame) return;
    final luma = lumaFrameFromCameraImage(
      image,
      targetLongest: config.analysisSize,
    );
    if (luma == null) return;
    detector.submit(luma, quarterTurns: quarterTurns);
  }

  void _onDetection() {
    if (_disposed) return;
    final detector = _detector;
    if (detector == null) return;
    _update = detector.update;
    _rearmAutoCapture();
    _maybeAutoCapture();
    _notify();
  }

  /// Auto-capture re-arms only once the page moved (or disappeared and came
  /// back), so a still sheet is captured exactly once.
  void _rearmAutoCapture() {
    if (_autoArmed) return;
    final current = _update.corners;
    final last = _lastCapturedCorners;
    if (current == null ||
        last == null ||
        !current.isCloseTo(last, tolerance: 0.06)) {
      _autoArmed = true;
    }
  }

  void _maybeAutoCapture() {
    if (!_autoCapture ||
        !_autoArmed ||
        _capturing ||
        _paused ||
        _disposed ||
        !_update.stable ||
        _update.corners == null) {
      return;
    }
    final last = _lastCaptureAt;
    if (last != null &&
        DateTime.now().difference(last) < config.autoCaptureCooldown) {
      return;
    }
    _autoArmed = false;
    unawaited(capture());
  }

  void _onCameraChanged() {
    if (!_disposed) _notify();
  }

  Future<void> _startStream() async {
    final camera = _camera;
    if (camera == null ||
        _streaming ||
        _paused ||
        _inactive ||
        !camera.value.isInitialized) {
      return;
    }
    try {
      await camera.startImageStream(_onFrame);
      _streaming = true;
    } catch (error) {
      _warning =
          'Live page detection is unavailable on this camera; use the shutter '
          'and adjust edges after capture.';
    }
  }

  Future<void> _stopStream() async {
    final camera = _camera;
    if (!_streaming || camera == null) return;
    _streaming = false;
    try {
      await camera.stopImageStream();
    } catch (_) {
      // Already stopped (e.g. camera went away); nothing to do.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      if (_inactive) return;
      _inactive = true;
      unawaited(_releaseCamera());
    } else if (state == AppLifecycleState.resumed) {
      if (!_inactive) return;
      _inactive = false;
      unawaited(initialize());
    }
  }

  /// Releases the camera hardware and the detector isolate.
  Future<void> _releaseCamera() async {
    final camera = _camera;
    final detector = _detector;
    _camera = null;
    _detector = null;
    _cameraReady = false;
    _streaming = false;
    _update = LiveScanUpdate.empty;

    if (camera != null) camera.removeListener(_onCameraChanged);
    if (detector != null) {
      detector.removeListener(_onDetection);
      await detector.stop();
      detector.dispose();
    }
    if (camera != null) {
      try {
        await camera.dispose();
      } catch (_) {
        // Best effort: the platform may already have released it.
      }
    }
    if (!_disposed) _notify();
  }

  String _cameraErrorMessage(CameraException error) {
    switch (error.code) {
      case 'CameraAccessDenied':
      case 'CameraAccessDeniedWithoutPrompt':
      case 'CameraAccessRestricted':
        return 'Camera access was denied. Allow the camera permission in '
            'system settings, then try again.';
      case 'cameraPermission':
        return 'Camera permission is required to scan.';
      case 'NoCamera':
        return 'No camera was found on this device.';
      default:
        return error.description ?? 'The camera could not be opened '
            '(${error.code}).';
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_releaseCamera());
    super.dispose();
  }
}
