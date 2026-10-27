// Gene - Oct, 27, 2026: ScrollingCaptureController manages the lifecycle of panoramic scrolling capture sessions, background image stitching, and disk storage.
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import '../capture_service.dart';
import 'image_stitcher.dart';
import 'native_scroll_service.dart';

enum ScrollingCaptureStatus {
  idle,
  initializing,
  capturing,
  paused,
  stitching,
  completed,
  cancelled,
}

class ScrollingCaptureController extends ChangeNotifier {
  final NativeScrollService _nativeService;
  final ImageStitcher _stitcher;
  final CaptureService _captureService;
  final Future<Directory> Function()? storageDirectoryProvider;

  ScrollingCaptureStatus _status = ScrollingCaptureStatus.idle;
  ScrollingCaptureStatus get status => _status;

  img.Image? _composite;
  Timer? _sampleTimer;
  Rect _viewport = Rect.zero;
  double _ratio = 1.0;
  int _frameCount = 0;
  bool _isProcessingFrame = false;
  bool _disposed = false;
  String? _lastSavedPath;

  int get cumulativeHeight => _composite?.height ?? 0;
  int get frameCount => _frameCount;
  String? get lastSavedPath => _lastSavedPath;

  ScrollingCaptureController({
    NativeScrollService? nativeService,
    ImageStitcher? stitcher,
    CaptureService? captureService,
    this.storageDirectoryProvider,
  }) : _nativeService = nativeService ?? PlatformNativeScrollService(),
       _stitcher = stitcher ?? ImageStitcher(),
       _captureService = captureService ?? CaptureService();

  Future<void> startCapture({
    required Rect viewportRect,
    required double devicePixelRatio,
    Duration samplingInterval = const Duration(milliseconds: 120),
  }) async {
    if (_disposed) return;
    _viewport = viewportRect;
    _ratio = devicePixelRatio;
    _frameCount = 0;
    _lastSavedPath = null;
    _composite = null;
    _status = ScrollingCaptureStatus.initializing;
    notifyListeners();

    // Grab initial base frame
    final bytes = await _nativeService.captureRectBytes(
      _viewport,
      devicePixelRatio: _ratio,
    );
    if (_disposed || _status == ScrollingCaptureStatus.cancelled) return;

    if (bytes == null) {
      _status = ScrollingCaptureStatus.cancelled;
      notifyListeners();
      return;
    }

    final decoded = img.decodePng(bytes);
    if (decoded == null) {
      _status = ScrollingCaptureStatus.cancelled;
      notifyListeners();
      return;
    }

    _composite = decoded;
    _frameCount = 1;
    _status = ScrollingCaptureStatus.capturing;
    notifyListeners();

    _sampleTimer?.cancel();
    _sampleTimer = Timer.periodic(
      samplingInterval,
      (_) => unawaited(_sampleNextFrame()),
    );
  }

  Future<void> _sampleNextFrame() async {
    if (_disposed ||
        _status != ScrollingCaptureStatus.capturing ||
        _isProcessingFrame) {
      return;
    }
    _isProcessingFrame = true;

    try {
      final bytes = await _nativeService.captureRectBytes(
        _viewport,
        devicePixelRatio: _ratio,
      );
      if (_disposed || _status != ScrollingCaptureStatus.capturing) return;

      if (bytes != null && _composite != null) {
        final newFrame = img.decodePng(bytes);
        if (newFrame != null) {
          final currentComposite = _composite!;
          final stitchResult = await compute<_StitchInput, _WorkerResult?>(
            _stitchWorker,
            _StitchInput(
              composite: currentComposite,
              newFrame: newFrame,
              ignoreMargin: _stitcher.scrollbarIgnoreMargin,
              maxError: _stitcher.maxMatchError,
              maxCumulativeHeight: _stitcher.maxCumulativeHeight,
            ),
          );

          if (_disposed || _status != ScrollingCaptureStatus.capturing) return;

          if (stitchResult != null && stitchResult.shiftY > 0) {
            _composite = stitchResult.newComposite;
            _frameCount++;
            notifyListeners();
          }
        }
      }
    } finally {
      _isProcessingFrame = false;
    }
  }

  void pauseCapture() {
    if (_status == ScrollingCaptureStatus.capturing) {
      _status = ScrollingCaptureStatus.paused;
      notifyListeners();
    }
  }

  void resumeCapture() {
    if (_status == ScrollingCaptureStatus.paused) {
      _status = ScrollingCaptureStatus.capturing;
      notifyListeners();
    }
  }

  Future<String?> finishCapture() async {
    _sampleTimer?.cancel();
    _sampleTimer = null;

    while (_isProcessingFrame) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    if (_composite == null || _status == ScrollingCaptureStatus.cancelled) {
      _status = ScrollingCaptureStatus.cancelled;
      notifyListeners();
      return null;
    }

    _status = ScrollingCaptureStatus.stitching;
    notifyListeners();

    try {
      final snapDir = storageDirectoryProvider != null
          ? await storageDirectoryProvider!()
          : await _captureService.getStorageDirectory();

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final path = p.join(snapDir.path, 'snap_scroll_$timestamp.png');

      final compositeToEncode = _composite!;
      final pngBytes = await compute<img.Image, Uint8List>(
        _encodePngWorker,
        compositeToEncode,
      );

      await File(path).writeAsBytes(pngBytes);
      _lastSavedPath = path;
      _status = ScrollingCaptureStatus.completed;
      notifyListeners();
      return path;
    } catch (e) {
      debugPrint('Error finishing scrolling capture: $e');
      _status = ScrollingCaptureStatus.cancelled;
      notifyListeners();
      return null;
    }
  }

  void cancelCapture() {
    _sampleTimer?.cancel();
    _sampleTimer = null;
    _composite = null;
    _status = ScrollingCaptureStatus.cancelled;
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_disposed) {
      super.notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _sampleTimer?.cancel();
    _sampleTimer = null;
    _composite = null;
    super.dispose();
  }
}

class _StitchInput {
  final img.Image composite;
  final img.Image newFrame;
  final int ignoreMargin;
  final double maxError;
  final int maxCumulativeHeight;

  _StitchInput({
    required this.composite,
    required this.newFrame,
    required this.ignoreMargin,
    required this.maxError,
    required this.maxCumulativeHeight,
  });
}

class _WorkerResult {
  final int shiftY;
  final img.Image newComposite;

  _WorkerResult(this.shiftY, this.newComposite);
}

_WorkerResult? _stitchWorker(_StitchInput input) {
  final stitcher = ImageStitcher(
    scrollbarIgnoreMargin: input.ignoreMargin,
    maxMatchError: input.maxError,
    maxCumulativeHeight: input.maxCumulativeHeight,
  );
  final result = stitcher.stitchFrame(
    composite: input.composite,
    newFrame: input.newFrame,
  );
  if (result.isMatchValid && result.shiftY > 0) {
    return _WorkerResult(result.shiftY, input.composite);
  }
  return null;
}

Uint8List _encodePngWorker(img.Image image) {
  return Uint8List.fromList(img.encodePng(image));
}
