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
  // Gene - Nov, 20, 2026: Native Rust engine flag & reactive state for macOS/Windows + O(N) strip accumulator for Linux fallback.
  final bool useNativeEngine;

  static bool get supportsNativeRustEngine =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows);

  ScrollingCaptureStatus _status = ScrollingCaptureStatus.idle;
  ScrollingCaptureStatus get status => _status;

  // Old implementation:
  // img.Image? _composite;
  StitchStripSession? _stripSession;
  Timer? _sampleTimer;
  Rect _viewport = Rect.zero;
  double _ratio = 1.0;
  int _frameCount = 0;
  int _nativeWidth = 0;
  int _nativeHeight = 0;
  int _activeAxis = 1;
  bool _isAutoScrolling = false;
  String? _warningMessage;
  Completer<String?>? _nativeCompleter;
  bool _isProcessingFrame = false;
  bool _disposed = false;
  String? _lastSavedPath;

  // Old implementation:
  // int get cumulativeHeight => _composite?.height ?? 0;
  int get cumulativeWidth =>
      useNativeEngine ? _nativeWidth : (_stripSession?.width ?? 0);
  int get cumulativeHeight =>
      useNativeEngine ? _nativeHeight : (_stripSession?.cumulativeHeight ?? 0);
  int get frameCount => _frameCount;
  int get activeAxis => _activeAxis;
  bool get isAutoScrolling => _isAutoScrolling;
  String? get warningMessage => _warningMessage;
  String? get lastSavedPath => _lastSavedPath;

  ScrollingCaptureController({
    NativeScrollService? nativeService,
    ImageStitcher? stitcher,
    CaptureService? captureService,
    this.storageDirectoryProvider,
    this.useNativeEngine = false,
  }) : _nativeService = nativeService ?? PlatformNativeScrollService(),
       _stitcher = stitcher ?? ImageStitcher(),
       _captureService = captureService ?? CaptureService();

  Future<void> startCapture({
    required Rect viewportRect,
    required double devicePixelRatio,
    Duration samplingInterval = const Duration(milliseconds: 120),
    int maxDimension = 16000,
    int axisMode = 0,
  }) async {
    if (_disposed) return;
    _viewport = viewportRect;
    _ratio = devicePixelRatio;
    _frameCount = 0;
    _nativeWidth = 0;
    _nativeHeight = 0;
    _activeAxis = 1;
    _isAutoScrolling = false;
    _warningMessage = null;
    _lastSavedPath = null;
    _stripSession?.clear();
    _stripSession = null;
    _status = ScrollingCaptureStatus.initializing;
    notifyListeners();

    if (useNativeEngine) {
      await _startNativeEngineCapture(
        viewportRect: viewportRect,
        maxDimension: maxDimension,
        axisMode: axisMode,
      );
      return;
    }

    // Grab initial base frame (Linux / fallback / test path)
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

    final session = StitchStripSession(stitcher: _stitcher);
    session.pushFrame(decoded);
    _stripSession = session;
    _frameCount = 1;
    _status = ScrollingCaptureStatus.capturing;
    notifyListeners();

    _sampleTimer?.cancel();
    _sampleTimer = Timer.periodic(
      samplingInterval,
      (_) => unawaited(_sampleNextFrame()),
    );
  }

  Future<void> _startNativeEngineCapture({
    required Rect viewportRect,
    required int maxDimension,
    required int axisMode,
  }) async {
    try {
      final snapDir = storageDirectoryProvider != null
          ? await storageDirectoryProvider!()
          : await _captureService.getStorageDirectory();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final outPath = p.join(snapDir.path, 'snap_scroll_$ts.png');
      final completer = Completer<String?>();
      _nativeCompleter = completer;

      _captureService.setScrollingCallbacks(
        onProgress: (map) {
          if (_disposed) return;
          _nativeWidth = (map['width'] as num?)?.toInt() ?? _nativeWidth;
          _nativeHeight = (map['height'] as num?)?.toInt() ?? _nativeHeight;
          _frameCount = (map['frameCount'] as num?)?.toInt() ?? _frameCount;
          _activeAxis = (map['axis'] as num?)?.toInt() ?? _activeAxis;
          final paused = map['isPaused'] == true;
          _isAutoScrolling = map['isAutoScrolling'] == true;
          _warningMessage = map['warning'] as String?;
          if (_status != ScrollingCaptureStatus.completed &&
              _status != ScrollingCaptureStatus.cancelled) {
            _status = paused
                ? ScrollingCaptureStatus.paused
                : ScrollingCaptureStatus.capturing;
          }
          notifyListeners();
        },
        onCompleted: (map) {
          final path = map['path'] as String?;
          _nativeWidth = (map['width'] as num?)?.toInt() ?? _nativeWidth;
          _nativeHeight = (map['height'] as num?)?.toInt() ?? _nativeHeight;
          _frameCount = (map['frameCount'] as num?)?.toInt() ?? _frameCount;
          _activeAxis = (map['axis'] as num?)?.toInt() ?? _activeAxis;
          if (map['truncated'] == true) {
            _warningMessage = 'Reached max scroll dimension; image truncated.';
          }
          _lastSavedPath = path;
          if (!_disposed) {
            _status = path != null
                ? ScrollingCaptureStatus.completed
                : ScrollingCaptureStatus.cancelled;
            notifyListeners();
          }
          if (!completer.isCompleted) completer.complete(path);
        },
        onCancel: () {
          if (!_disposed) {
            _status = ScrollingCaptureStatus.cancelled;
            notifyListeners();
          }
          if (!completer.isCompleted) completer.complete(null);
        },
        onError: (msg) {
          _warningMessage = msg;
          if (!_disposed) {
            _status = ScrollingCaptureStatus.cancelled;
            notifyListeners();
          }
          if (!completer.isCompleted) completer.complete(null);
        },
      );

      final started = await _captureService.startScrollingCapture(
        viewportRect,
        targetPath: outPath,
        maxDimension: maxDimension,
        axisMode: axisMode,
      );
      if (!started) {
        _status = ScrollingCaptureStatus.cancelled;
        notifyListeners();
        if (!completer.isCompleted) completer.complete(null);
        return;
      }
      _status = ScrollingCaptureStatus.capturing;
      notifyListeners();
    } catch (e) {
      debugPrint('SnipSnap native scrolling start failed: $e');
      _status = ScrollingCaptureStatus.cancelled;
      notifyListeners();
      if (!(_nativeCompleter?.isCompleted ?? true)) {
        _nativeCompleter?.complete(null);
      }
    }
  }

  Future<String?> waitForNativeCompletion() async {
    final completer = _nativeCompleter;
    if (completer == null) return _lastSavedPath;
    return completer.future;
  }

  Future<void> setAutoScroll(bool enabled) async {
    if (!useNativeEngine) return;
    _isAutoScrolling = enabled;
    notifyListeners();
    await _captureService.setScrollingAutoMode(enabled);
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

      final tail = _stripSession?.tailFrame;
      if (bytes != null && tail != null) {
        final newFrame = img.decodePng(bytes);
        if (newFrame != null) {
          // Gene - Nov, 20, 2026: Ship only tail frame + newFrame across isolate (O(1) memory) instead of full composite.
          // Old implementation:
          // final stitchResult = await compute<_StitchInput, _WorkerResult?>(
          //   _stitchWorker,
          //   _StitchInput(composite: currentComposite, newFrame: newFrame, ...),
          // );
          final shiftY = await compute<_ShiftInput, int>(
            _findShiftWorker,
            _ShiftInput(
              tailFrame: tail,
              newFrame: newFrame,
              ignoreMargin: _stitcher.scrollbarIgnoreMargin,
              maxError: _stitcher.maxMatchError,
            ),
          );

          if (_disposed || _status != ScrollingCaptureStatus.capturing) return;

          if (shiftY > 0) {
            _stripSession?.appendShiftSlice(frame: newFrame, shiftY: shiftY);
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
      if (useNativeEngine) {
        unawaited(_captureService.pauseScrollingCapture());
      }
    }
  }

  void resumeCapture() {
    if (_status == ScrollingCaptureStatus.paused) {
      _status = ScrollingCaptureStatus.capturing;
      notifyListeners();
      if (useNativeEngine) {
        unawaited(_captureService.resumeScrollingCapture());
      }
    }
  }

  Future<String?> finishCapture() async {
    if (_status == ScrollingCaptureStatus.idle ||
        _status == ScrollingCaptureStatus.cancelled) {
      _status = ScrollingCaptureStatus.cancelled;
      notifyListeners();
      return null;
    }

    if (useNativeEngine) {
      _status = ScrollingCaptureStatus.stitching;
      notifyListeners();
      await _captureService.finishScrollingCapture();
      return waitForNativeCompletion();
    }

    _sampleTimer?.cancel();
    _sampleTimer = null;

    while (_isProcessingFrame) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    final composite = _stripSession?.assemble();
    if (composite == null || _status == ScrollingCaptureStatus.cancelled) {
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

      final pngBytes = await compute<img.Image, Uint8List>(
        _encodePngWorker,
        composite,
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
    if (useNativeEngine) {
      unawaited(_captureService.cancelScrollingCapture());
    }
    _sampleTimer?.cancel();
    _sampleTimer = null;
    _stripSession?.clear();
    _stripSession = null;
    _status = ScrollingCaptureStatus.cancelled;
    notifyListeners();
    if (!(_nativeCompleter?.isCompleted ?? true)) {
      _nativeCompleter?.complete(null);
    }
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
    _stripSession?.clear();
    _stripSession = null;
    if (!(_nativeCompleter?.isCompleted ?? true)) {
      _nativeCompleter?.complete(null);
    }
    super.dispose();
  }
}

// Old implementation:
// class _StitchInput {
//   final img.Image composite;
//   final img.Image newFrame;
//   final int ignoreMargin;
//   final double maxError;
//   final int maxCumulativeHeight;
//
//   _StitchInput({
//     required this.composite,
//     required this.newFrame,
//     required this.ignoreMargin,
//     required this.maxError,
//     required this.maxCumulativeHeight,
//   });
// }
//
// class _WorkerResult {
//   final int shiftY;
//   final img.Image newComposite;
//
//   _WorkerResult(this.shiftY, this.newComposite);
// }
//
// _WorkerResult? _stitchWorker(_StitchInput input) {
//   final stitcher = ImageStitcher(
//     scrollbarIgnoreMargin: input.ignoreMargin,
//     maxMatchError: input.maxError,
//     maxCumulativeHeight: input.maxCumulativeHeight,
//   );
//   final result = stitcher.stitchFrame(
//     composite: input.composite,
//     newFrame: input.newFrame,
//   );
//   if (result.isMatchValid && result.shiftY > 0) {
//     return _WorkerResult(result.shiftY, input.composite);
//   }
//   return null;
// }
//
// Uint8List _encodePngWorker(img.Image image) {
//   return Uint8List.fromList(img.encodePng(image));
// }

// Gene - Nov, 20, 2026: Lightweight tail-frame shift worker & fast level-1 PNG worker for Linux fallback.
class _ShiftInput {
  final img.Image tailFrame;
  final img.Image newFrame;
  final int ignoreMargin;
  final double maxError;

  _ShiftInput({
    required this.tailFrame,
    required this.newFrame,
    required this.ignoreMargin,
    required this.maxError,
  });
}

int _findShiftWorker(_ShiftInput input) {
  return ImageStitcher.findVerticalShift(
    base: input.tailFrame,
    next: input.newFrame,
    ignoreRightMargin: input.ignoreMargin,
    maxError: input.maxError,
  );
}

Uint8List _encodePngWorker(img.Image image) {
  return Uint8List.fromList(img.encodePng(image, level: 1));
}
