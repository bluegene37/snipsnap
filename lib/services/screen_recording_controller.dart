// Gene - Nov, 08, 2026: Created ScreenRecordingController for whole-screen and selected-area H.264 MP4 recording lifecycle, timer, and video utilities.
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import '../models/capture_item.dart';
import 'capture_service.dart';

enum ScreenRecordingState {
  idle,
  recording,
  paused,
  stopping,
}

class ScreenRecordingResult {
  final String filePath;
  final String? thumbnailPath;
  final int durationMs;
  final int width;
  final int height;
  final bool hasAudio;

  const ScreenRecordingResult({
    required this.filePath,
    this.thumbnailPath,
    required this.durationMs,
    required this.width,
    required this.height,
    required this.hasAudio,
  });

  CaptureItem toCaptureItem({String? customTitle}) {
    final now = DateTime.now();
    return CaptureItem(
      id: 'rec_${now.millisecondsSinceEpoch}',
      filePath: filePath,
      createdAt: now,
      width: width,
      height: height,
      title: customTitle ?? 'Screen Recording',
      mediaType: CaptureMediaType.video,
      durationMs: durationMs,
      hasAudio: hasAudio,
      thumbnailPath: (thumbnailPath != null && thumbnailPath!.isNotEmpty)
          ? thumbnailPath
          : null,
    );
  }
}

class ScreenRecordingController extends ChangeNotifier {
  final CaptureService captureService;
  final ValueChanged<ScreenRecordingResult>? onRecordingCompleted;
  final VoidCallback? onRecordingCancelled;

  ScreenRecordingState _state = ScreenRecordingState.idle;
  Duration _elapsed = Duration.zero;
  bool _recordMicrophone = false;
  bool _isFullScreen = true;
  Rect? _activeRegion;
  Timer? _uiTimer;
  DateTime? _segmentStartTime;
  Duration _accumulatedBeforePause = Duration.zero;

  ScreenRecordingController({
    required this.captureService,
    this.onRecordingCompleted,
    this.onRecordingCancelled,
  }) {
    captureService.setRecordingCallbacks(
      onStopped: _handleNativeRecordingStopped,
      onCancelled: _handleNativeRecordingCancelled,
      onStateChanged: _handleNativeStateChanged,
    );
  }

  ScreenRecordingState get state => _state;
  bool get isRecording =>
      _state == ScreenRecordingState.recording ||
      _state == ScreenRecordingState.paused;
  bool get isPaused => _state == ScreenRecordingState.paused;
  bool get isStopping => _state == ScreenRecordingState.stopping;
  Duration get elapsed => _elapsed;
  bool get recordMicrophone => _recordMicrophone;
  bool get isFullScreen => _isFullScreen;
  Rect? get activeRegion => _activeRegion;

  String get formattedElapsed {
    final totalSecs = _elapsed.inSeconds;
    final mins = (totalSecs ~/ 60).toString().padLeft(2, '0');
    final secs = (totalSecs % 60).toString().padLeft(2, '0');
    return '$mins:$secs';
  }

  void setRecordMicrophone(bool value) {
    if (_recordMicrophone == value) return;
    _recordMicrophone = value;
    notifyListeners();
  }

  Future<bool> startFullScreenRecording({int fps = 30}) async {
    if (isRecording || isStopping) return false;
    final targetPath = await captureService.generateNewMediaPath(
      prefix: 'rec',
      extension: 'mp4',
    );
    final thumbnailPath = await captureService.generateNewMediaPath(
      prefix: 'rec_thumb',
      extension: 'png',
    );

    final ok = await captureService.startScreenRecording(
      targetPath: targetPath,
      thumbnailPath: thumbnailPath,
      fullScreen: true,
      fps: fps,
      recordAudio: _recordMicrophone,
    );
    if (!ok) return false;

    _isFullScreen = true;
    _activeRegion = null;
    _beginTimerState();
    return true;
  }

  Future<bool> startAreaRecording(Rect region, {int fps = 30}) async {
    if (isRecording || isStopping) return false;
    final targetPath = await captureService.generateNewMediaPath(
      prefix: 'rec',
      extension: 'mp4',
    );
    final thumbnailPath = await captureService.generateNewMediaPath(
      prefix: 'rec_thumb',
      extension: 'png',
    );

    final ok = await captureService.startScreenRecording(
      targetPath: targetPath,
      thumbnailPath: thumbnailPath,
      fullScreen: false,
      region: region,
      fps: fps,
      recordAudio: _recordMicrophone,
    );
    if (!ok) return false;

    _isFullScreen = false;
    _activeRegion = region;
    _beginTimerState();
    return true;
  }

  void _beginTimerState() {
    _state = ScreenRecordingState.recording;
    _elapsed = Duration.zero;
    _accumulatedBeforePause = Duration.zero;
    _segmentStartTime = DateTime.now();
    _uiTimer?.cancel();
    _uiTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (_state == ScreenRecordingState.recording &&
          _segmentStartTime != null) {
        _elapsed =
            _accumulatedBeforePause +
            DateTime.now().difference(_segmentStartTime!);
        notifyListeners();
      }
    });
    notifyListeners();
  }

  Future<void> togglePause() async {
    if (_state == ScreenRecordingState.recording) {
      final ok = await captureService.pauseScreenRecording();
      if (ok) {
        if (_segmentStartTime != null) {
          _accumulatedBeforePause +=
              DateTime.now().difference(_segmentStartTime!);
        }
        _segmentStartTime = null;
        _state = ScreenRecordingState.paused;
        notifyListeners();
      }
    } else if (_state == ScreenRecordingState.paused) {
      final ok = await captureService.resumeScreenRecording();
      if (ok) {
        _segmentStartTime = DateTime.now();
        _state = ScreenRecordingState.recording;
        notifyListeners();
      }
    }
  }

  Future<ScreenRecordingResult?> stopRecording() async {
    if (!isRecording) return null;
    _state = ScreenRecordingState.stopping;
    _uiTimer?.cancel();
    _uiTimer = null;
    notifyListeners();

    final info = await captureService.stopScreenRecording();
    _resetToIdle();
    if (info == null) return null;

    final result = _parseRecordingInfo(info);
    if (result != null) {
      onRecordingCompleted?.call(result);
    }
    return result;
  }

  Future<void> cancelRecording() async {
    if (!isRecording && !isStopping) return;
    _uiTimer?.cancel();
    _uiTimer = null;
    await captureService.cancelScreenRecording();
    _resetToIdle();
    onRecordingCancelled?.call();
  }

  void _handleNativeRecordingStopped(Map<String, dynamic> info) {
    _uiTimer?.cancel();
    _uiTimer = null;
    _resetToIdle();
    final result = _parseRecordingInfo(info);
    if (result != null) {
      onRecordingCompleted?.call(result);
    }
  }

  void _handleNativeRecordingCancelled() {
    _uiTimer?.cancel();
    _uiTimer = null;
    _resetToIdle();
    onRecordingCancelled?.call();
  }

  void _handleNativeStateChanged(bool paused) {
    if (!isRecording) return;
    if (paused && _state == ScreenRecordingState.recording) {
      if (_segmentStartTime != null) {
        _accumulatedBeforePause +=
            DateTime.now().difference(_segmentStartTime!);
      }
      _segmentStartTime = null;
      _state = ScreenRecordingState.paused;
      notifyListeners();
    } else if (!paused && _state == ScreenRecordingState.paused) {
      _segmentStartTime = DateTime.now();
      _state = ScreenRecordingState.recording;
      notifyListeners();
    }
  }

  ScreenRecordingResult? _parseRecordingInfo(Map<String, dynamic> info) {
    final filePath = info['filePath'] as String?;
    if (filePath == null || filePath.isEmpty) return null;
    final thumbnailPath = info['thumbnailPath'] as String?;
    final durationMs = (info['durationMs'] as num?)?.toInt() ??
        _elapsed.inMilliseconds.clamp(100, 36000000);
    final width = (info['width'] as num?)?.toInt() ?? 1920;
    final height = (info['height'] as num?)?.toInt() ?? 1080;
    final hasAudio = info['hasAudio'] == true;

    return ScreenRecordingResult(
      filePath: filePath,
      thumbnailPath: thumbnailPath,
      durationMs: durationMs,
      width: width,
      height: height,
      hasAudio: hasAudio,
    );
  }

  void _resetToIdle() {
    _state = ScreenRecordingState.idle;
    _elapsed = Duration.zero;
    _accumulatedBeforePause = Duration.zero;
    _segmentStartTime = null;
    _activeRegion = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _uiTimer?.cancel();
    super.dispose();
  }
}
