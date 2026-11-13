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
  // Gene - Nov, 13, 2026: Added 60fps default, microphone device selection, live mute, system audio loopback, cursor/click highlight options, and restart support.
  // Old implementation:
  // bool _recordMicrophone = false;
  // bool _isFullScreen = true;
  int _fps = 60;
  bool _recordMicrophone = false;
  String? _selectedMicrophoneId;
  List<AudioInputDevice> _availableMicrophones = const [];
  bool _recordSystemAudio = true;
  bool _recordCursor = true;
  bool _highlightClicks = true;
  bool _isMicrophoneMuted = false;
  bool _isFullScreen = true;
  Rect? _activeRegion;
  Timer? _uiTimer;
  DateTime? _segmentStartTime;
  Duration _accumulatedBeforePause = Duration.zero;

  // Gene - Nov, 13, 2026: Registered native restart and mic-mute callbacks.
  // Old implementation:
  // ScreenRecordingController({
  //   required this.captureService,
  //   this.onRecordingCompleted,
  //   this.onRecordingCancelled,
  // }) {
  //   captureService.setRecordingCallbacks(
  //     onStopped: _handleNativeRecordingStopped,
  //     onCancelled: _handleNativeRecordingCancelled,
  //     onStateChanged: _handleNativeStateChanged,
  //   );
  // }
  ScreenRecordingController({
    required this.captureService,
    this.onRecordingCompleted,
    this.onRecordingCancelled,
  }) {
    captureService.setRecordingCallbacks(
      onStopped: _handleNativeRecordingStopped,
      onCancelled: _handleNativeRecordingCancelled,
      onStateChanged: _handleNativeStateChanged,
      onRestartRequested: _handleNativeRestartRequested,
      onMicMutedChanged: _handleNativeMicMutedChanged,
    );
  }

  ScreenRecordingState get state => _state;
  bool get isRecording =>
      _state == ScreenRecordingState.recording ||
      _state == ScreenRecordingState.paused;
  bool get isPaused => _state == ScreenRecordingState.paused;
  bool get isStopping => _state == ScreenRecordingState.stopping;
  Duration get elapsed => _elapsed;
  int get fps => _fps;
  bool get recordMicrophone => _recordMicrophone;
  String? get selectedMicrophoneId => _selectedMicrophoneId;
  List<AudioInputDevice> get availableMicrophones =>
      List.unmodifiable(_availableMicrophones);
  bool get recordSystemAudio => _recordSystemAudio;
  bool get recordCursor => _recordCursor;
  bool get highlightClicks => _highlightClicks;
  bool get isMicrophoneMuted => _isMicrophoneMuted;
  bool get isFullScreen => _isFullScreen;
  Rect? get activeRegion => _activeRegion;

  String get formattedElapsed {
    final totalSecs = _elapsed.inSeconds;
    final mins = (totalSecs ~/ 60).toString().padLeft(2, '0');
    final secs = (totalSecs % 60).toString().padLeft(2, '0');
    return '$mins:$secs';
  }

  void setFps(int value) {
    final normalized = value >= 45 ? 60 : 30;
    if (_fps == normalized) return;
    _fps = normalized;
    notifyListeners();
  }

  void setRecordMicrophone(bool value) {
    if (_recordMicrophone == value) return;
    _recordMicrophone = value;
    notifyListeners();
  }

  void setSelectedMicrophoneId(String? deviceId) {
    if (_selectedMicrophoneId == deviceId) return;
    _selectedMicrophoneId = deviceId;
    notifyListeners();
  }

  void setRecordSystemAudio(bool value) {
    if (_recordSystemAudio == value) return;
    _recordSystemAudio = value;
    notifyListeners();
  }

  void setRecordCursor(bool value) {
    if (_recordCursor == value) return;
    _recordCursor = value;
    notifyListeners();
  }

  void setHighlightClicks(bool value) {
    if (_highlightClicks == value) return;
    _highlightClicks = value;
    notifyListeners();
  }

  Future<void> refreshAudioDevices() async {
    final devices = await captureService.listAudioInputDevices();
    _availableMicrophones = devices;
    if (_selectedMicrophoneId != null &&
        devices.every((d) => d.id != _selectedMicrophoneId)) {
      _selectedMicrophoneId = null;
    }
    if (_selectedMicrophoneId == null && devices.isNotEmpty) {
      final def = devices.where((d) => d.isDefault).firstOrNull;
      _selectedMicrophoneId = (def ?? devices.first).id;
    }
    notifyListeners();
  }

  Future<void> toggleMicrophoneMute() async {
    if (!isRecording || !_recordMicrophone) return;
    final nextMuted = !_isMicrophoneMuted;
    await captureService.setRecordingMicrophoneMuted(nextMuted);
    _isMicrophoneMuted = nextMuted;
    notifyListeners();
  }

  // Gene - Nov, 13, 2026: Default to 60fps, route thumbnails to .thumbnails/, and forward Snagit recording options (system audio, mic device, cursor, clicks, countdown).
  // Old implementation:
  // Future<bool> startFullScreenRecording({int fps = 30}) async {
  //   if (isRecording || isStopping) return false;
  //   final targetPath = await captureService.generateNewMediaPath(
  //     prefix: 'rec',
  //     extension: 'mp4',
  //   );
  //   final thumbnailPath = await captureService.generateNewMediaPath(
  //     prefix: 'rec_thumb',
  //     extension: 'png',
  //   );
  //
  //   final ok = await captureService.startScreenRecording(
  //     targetPath: targetPath,
  //     thumbnailPath: thumbnailPath,
  //     fullScreen: true,
  //     fps: fps,
  //     recordAudio: _recordMicrophone,
  //   );
  //   if (!ok) return false;
  //
  //   _isFullScreen = true;
  //   _activeRegion = null;
  //   _beginTimerState();
  //   return true;
  // }
  //
  // Future<bool> startAreaRecording(Rect region, {int fps = 30}) async {
  //   if (isRecording || isStopping) return false;
  //   final targetPath = await captureService.generateNewMediaPath(
  //     prefix: 'rec',
  //     extension: 'mp4',
  //   );
  //   final thumbnailPath = await captureService.generateNewMediaPath(
  //     prefix: 'rec_thumb',
  //     extension: 'png',
  //   );
  //
  //   final ok = await captureService.startScreenRecording(
  //     targetPath: targetPath,
  //     thumbnailPath: thumbnailPath,
  //     fullScreen: false,
  //     region: region,
  //     fps: fps,
  //     recordAudio: _recordMicrophone,
  //   );
  //   if (!ok) return false;
  //
  //   _isFullScreen = false;
  //   _activeRegion = region;
  //   _beginTimerState();
  //   return true;
  // }
  // Gene - Nov, 13, 2026: Accept optional displayRegion in startFullScreenRecording and preserve _activeRegion across restartRecording for multi-monitor full-screen capture.
  // Old implementation:
  // Future<bool> startFullScreenRecording({
  //   int? fps,
  //   int countdownSeconds = 0,
  // }) async {
  //   if (isRecording || isStopping) return false;
  //   final effectiveFps = fps ?? _fps;
  //   final targetPath = await captureService.generateNewMediaPath(
  //     prefix: 'rec',
  //     extension: 'mp4',
  //   );
  //   final thumbnailPath = await captureService.generateNewThumbnailPath(
  //     prefix: 'rec_thumb',
  //   );
  //
  //   final ok = await captureService.startScreenRecording(
  //     targetPath: targetPath,
  //     thumbnailPath: thumbnailPath,
  //     fullScreen: true,
  //     fps: effectiveFps,
  //     recordAudio: _recordMicrophone,
  //     microphoneDeviceId: _selectedMicrophoneId,
  //     recordSystemAudio: _recordSystemAudio,
  //     recordCursor: _recordCursor,
  //     highlightClicks: _highlightClicks,
  //     countdownSeconds: countdownSeconds,
  //   );
  //   if (!ok) return false;
  //
  //   _isFullScreen = true;
  //   _activeRegion = null;
  //   _isMicrophoneMuted = false;
  //   _beginTimerState(countdownDelaySeconds: countdownSeconds);
  //   return true;
  // }
  Future<bool> startFullScreenRecording({
    int? fps,
    int countdownSeconds = 0,
    Rect? displayRegion,
  }) async {
    if (isRecording || isStopping) return false;
    final effectiveFps = fps ?? _fps;
    final targetPath = await captureService.generateNewMediaPath(
      prefix: 'rec',
      extension: 'mp4',
    );
    final thumbnailPath = await captureService.generateNewThumbnailPath(
      prefix: 'rec_thumb',
    );

    final ok = await captureService.startScreenRecording(
      targetPath: targetPath,
      thumbnailPath: thumbnailPath,
      fullScreen: true,
      region: displayRegion,
      fps: effectiveFps,
      recordAudio: _recordMicrophone,
      microphoneDeviceId: _selectedMicrophoneId,
      recordSystemAudio: _recordSystemAudio,
      recordCursor: _recordCursor,
      highlightClicks: _highlightClicks,
      countdownSeconds: countdownSeconds,
    );
    if (!ok) return false;

    _isFullScreen = true;
    _activeRegion = displayRegion;
    _isMicrophoneMuted = false;
    _beginTimerState(countdownDelaySeconds: countdownSeconds);
    return true;
  }

  Future<bool> startAreaRecording(
    Rect region, {
    int? fps,
    int countdownSeconds = 0,
  }) async {
    if (isRecording || isStopping) return false;
    final effectiveFps = fps ?? _fps;
    final targetPath = await captureService.generateNewMediaPath(
      prefix: 'rec',
      extension: 'mp4',
    );
    final thumbnailPath = await captureService.generateNewThumbnailPath(
      prefix: 'rec_thumb',
    );

    final ok = await captureService.startScreenRecording(
      targetPath: targetPath,
      thumbnailPath: thumbnailPath,
      fullScreen: false,
      region: region,
      fps: effectiveFps,
      recordAudio: _recordMicrophone,
      microphoneDeviceId: _selectedMicrophoneId,
      recordSystemAudio: _recordSystemAudio,
      recordCursor: _recordCursor,
      highlightClicks: _highlightClicks,
      countdownSeconds: countdownSeconds,
    );
    if (!ok) return false;

    _isFullScreen = false;
    _activeRegion = region;
    _isMicrophoneMuted = false;
    _beginTimerState(countdownDelaySeconds: countdownSeconds);
    return true;
  }

  Future<bool> restartRecording({int countdownSeconds = 3}) async {
    if (!isRecording && !isStopping) return false;
    final wasFullScreen = _isFullScreen;
    final region = _activeRegion;
    _uiTimer?.cancel();
    _uiTimer = null;
    await captureService.cancelScreenRecording();
    _resetToIdle();
    // Gene - Nov, 13, 2026: Preserve secondary-monitor displayRegion when restarting a full-screen recording.
    // Old implementation:
    // if (wasFullScreen || region == null) {
    //   return await startFullScreenRecording(
    //     countdownSeconds: countdownSeconds,
    //   );
    // }
    if (wasFullScreen || region == null) {
      return await startFullScreenRecording(
        countdownSeconds: countdownSeconds,
        displayRegion: region,
      );
    }
    return await startAreaRecording(
      region,
      countdownSeconds: countdownSeconds,
    );
  }

  // Gene - Nov, 13, 2026: Added optional countdownDelaySeconds so timer stays at 00:00 during the 3-2-1 countdown.
  // Old implementation:
  // void _beginTimerState() {
  //   _state = ScreenRecordingState.recording;
  //   _elapsed = Duration.zero;
  //   _accumulatedBeforePause = Duration.zero;
  //   _segmentStartTime = DateTime.now();
  void _beginTimerState({int countdownDelaySeconds = 0}) {
    _state = ScreenRecordingState.recording;
    _elapsed = Duration.zero;
    _accumulatedBeforePause = Duration.zero;
    final now = DateTime.now();
    _segmentStartTime = countdownDelaySeconds > 0
        ? now.add(Duration(seconds: countdownDelaySeconds))
        : now;
    _uiTimer?.cancel();
    _uiTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (_state == ScreenRecordingState.recording &&
          _segmentStartTime != null) {
        final diff = DateTime.now().difference(_segmentStartTime!);
        _elapsed =
            _accumulatedBeforePause +
            (diff.isNegative ? Duration.zero : diff);
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
          // Gene - Nov, 13, 2026: Clamp segment diff so pausing before countdown ends never subtracts from accumulated duration.
          final diff = DateTime.now().difference(_segmentStartTime!);
          if (!diff.isNegative) {
            _accumulatedBeforePause += diff;
          }
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

  // Gene - Nov, 13, 2026: Handle native HUD Restart button and Mic Mute state sync.
  void _handleNativeRestartRequested() {
    unawaited(restartRecording());
  }

  void _handleNativeMicMutedChanged(bool muted) {
    if (_isMicrophoneMuted == muted) return;
    _isMicrophoneMuted = muted;
    notifyListeners();
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
    _isMicrophoneMuted = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _uiTimer?.cancel();
    super.dispose();
  }
}
