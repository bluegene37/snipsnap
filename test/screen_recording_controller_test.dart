// Gene - Nov, 08, 2026: Unit tests for ScreenRecordingController and ScreenRecordingResult.
// Gene - Nov, 13, 2026: Replaced painting.dart import with services.dart + dart:io for real CaptureService channel dispatch test.
// import 'package:flutter/painting.dart';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/models/capture_item.dart';
import 'package:snipsnap/services/capture_service.dart';
import 'package:snipsnap/services/screen_recording_controller.dart';

class _FakeRecordingCaptureService extends CaptureService {
  bool startResult = true;
  bool pauseResult = true;
  bool resumeResult = true;
  Map<String, dynamic>? stopResult = const {
    'filePath': '/tmp/rec_test.mp4',
    'thumbnailPath': '/tmp/rec_thumb_test.png',
    'durationMs': 4200,
    'width': 1920,
    'height': 1080,
    'hasAudio': true,
  };

  bool lastFullScreen = false;
  Rect? lastRegion;
  bool lastRecordAudio = false;
  int cancelCalls = 0;
  // Gene - Nov, 13, 2026: Track Snagit 60fps, thumbnail dir, system audio, cursor, click highlights, mic device, and mute calls in fake service.
  String? lastThumbnailPath;
  int lastFps = 0;
  String? lastMicDeviceId;
  bool lastRecordSystemAudio = false;
  bool lastRecordCursor = false;
  bool lastHighlightClicks = false;
  int lastCountdownSeconds = 0;
  bool? lastMuted;
  List<AudioInputDevice> fakeDevices = const [
    AudioInputDevice(id: 'mic_builtin', name: 'Built-in Mic', isDefault: true),
    AudioInputDevice(id: 'mic_usb', name: 'USB Podcast Mic', isDefault: false),
  ];

  @override
  Future<String> generateNewMediaPath({
    String prefix = 'snip',
    String extension = 'png',
  }) async {
    return '/tmp/${prefix}_mock.$extension';
  }

  @override
  Future<String> generateNewThumbnailPath({
    String prefix = 'rec_thumb',
  }) async {
    return '/tmp/.thumbnails/${prefix}_mock.png';
  }

  @override
  Future<List<AudioInputDevice>> listAudioInputDevices() async {
    return fakeDevices;
  }

  @override
  Future<bool> setRecordingMicrophoneMuted(bool muted) async {
    lastMuted = muted;
    return true;
  }

  // Gene - Nov, 13, 2026: Updated startScreenRecording mock signature for 60fps, mic device, system audio, cursor/click highlight, and countdown parameters.
  // Old implementation:
  // @override
  // Future<bool> startScreenRecording({
  //   required String targetPath,
  //   required String thumbnailPath,
  //   bool fullScreen = true,
  //   Rect? region,
  //   int fps = 30,
  //   bool recordAudio = false,
  // }) async {
  //   lastFullScreen = fullScreen;
  //   lastRegion = region;
  //   lastRecordAudio = recordAudio;
  //   return startResult;
  // }
  @override
  Future<bool> startScreenRecording({
    required String targetPath,
    required String thumbnailPath,
    required bool fullScreen,
    Rect? region,
    int fps = 60,
    bool recordAudio = false,
    String? microphoneDeviceId,
    bool recordSystemAudio = true,
    bool recordCursor = true,
    bool highlightClicks = true,
    int countdownSeconds = 0,
  }) async {
    lastThumbnailPath = thumbnailPath;
    lastFullScreen = fullScreen;
    lastRegion = region;
    lastFps = fps;
    lastRecordAudio = recordAudio;
    lastMicDeviceId = microphoneDeviceId;
    lastRecordSystemAudio = recordSystemAudio;
    lastRecordCursor = recordCursor;
    lastHighlightClicks = highlightClicks;
    lastCountdownSeconds = countdownSeconds;
    return startResult;
  }

  @override
  Future<bool> pauseScreenRecording() async => pauseResult;

  @override
  Future<bool> resumeScreenRecording() async => resumeResult;

  @override
  Future<Map<String, dynamic>?> stopScreenRecording() async => stopResult;

  @override
  Future<void> cancelScreenRecording() async {
    cancelCalls++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ScreenRecordingController', () {
    late _FakeRecordingCaptureService fakeService;
    late ScreenRecordingController controller;
    ScreenRecordingResult? completedResult;
    int cancelledCount = 0;

    setUp(() {
      fakeService = _FakeRecordingCaptureService();
      completedResult = null;
      cancelledCount = 0;
      controller = ScreenRecordingController(
        captureService: fakeService,
        onRecordingCompleted: (res) => completedResult = res,
        onRecordingCancelled: () => cancelledCount++,
      );
    });

    tearDown(() {
      controller.dispose();
    });

    test('starts full-screen recording, pauses, resumes, and stops', () async {
      controller.setRecordMicrophone(true);
      expect(controller.recordMicrophone, isTrue);

      final started = await controller.startFullScreenRecording();
      expect(started, isTrue);
      expect(controller.isRecording, isTrue);
      expect(controller.isPaused, isFalse);
      expect(controller.isFullScreen, isTrue);
      expect(fakeService.lastFullScreen, isTrue);
      expect(fakeService.lastRecordAudio, isTrue);

      await controller.togglePause();
      expect(controller.isPaused, isTrue);
      expect(controller.state, ScreenRecordingState.paused);

      await controller.togglePause();
      expect(controller.isPaused, isFalse);
      expect(controller.state, ScreenRecordingState.recording);

      final result = await controller.stopRecording();
      expect(result, isNotNull);
      expect(completedResult, isNotNull);
      expect(controller.isRecording, isFalse);
      expect(controller.state, ScreenRecordingState.idle);

      final item = result!.toCaptureItem(customTitle: 'Demo Video');
      expect(item.isVideo, isTrue);
      expect(item.mediaType, CaptureMediaType.video);
      expect(item.durationMs, 4200);
      expect(item.width, 1920);
      expect(item.height, 1080);
      expect(item.hasAudio, isTrue);
      expect(item.title, 'Demo Video');
    });

    test('starts selected-area recording and supports cancel', () async {
      const region = Rect.fromLTWH(100, 120, 800, 600);
      final started = await controller.startAreaRecording(region);
      expect(started, isTrue);
      expect(controller.isFullScreen, isFalse);
      expect(controller.activeRegion, region);
      expect(fakeService.lastRegion, region);

      await controller.cancelRecording();
      expect(controller.isRecording, isFalse);
      expect(cancelledCount, 1);
      expect(fakeService.cancelCalls, 1);
    });

    // Gene - Nov, 13, 2026: Added tests for 60fps defaults, thumbnail path isolation, audio device selection, mic mute, and restartRecording.
    test(
      'defaults to 60fps, system audio, cursor+click highlight, and .thumbnails/ path',
      () async {
        expect(controller.fps, 60);
        expect(controller.recordSystemAudio, isTrue);
        expect(controller.recordCursor, isTrue);
        expect(controller.highlightClicks, isTrue);

        final started = await controller.startFullScreenRecording();
        expect(started, isTrue);
        expect(fakeService.lastFps, 60);
        expect(fakeService.lastRecordSystemAudio, isTrue);
        expect(fakeService.lastRecordCursor, isTrue);
        expect(fakeService.lastHighlightClicks, isTrue);
        expect(fakeService.lastThumbnailPath, contains('/.thumbnails/'));
      },
    );

    test(
      'refreshes audio devices, selects mic, and toggles live mute',
      () async {
        await controller.refreshAudioDevices();
        expect(controller.availableMicrophones, hasLength(2));
        expect(controller.selectedMicrophoneId, 'mic_builtin');

        controller.setSelectedMicrophoneId('mic_usb');
        expect(controller.selectedMicrophoneId, 'mic_usb');

        controller.setRecordMicrophone(true);
        await controller.startFullScreenRecording();
        expect(fakeService.lastMicDeviceId, 'mic_usb');

        expect(controller.isMicrophoneMuted, isFalse);
        await controller.toggleMicrophoneMute();
        expect(controller.isMicrophoneMuted, isTrue);
        expect(fakeService.lastMuted, isTrue);
      },
    );

    test('restartRecording cancels current capture and restarts same region', () async {
      const region = Rect.fromLTWH(50, 60, 1280, 720);
      final started = await controller.startAreaRecording(region);
      expect(started, isTrue);

      final restarted = await controller.restartRecording(countdownSeconds: 3);
      expect(restarted, isTrue);
      expect(fakeService.cancelCalls, 1);
      expect(controller.isRecording, isTrue);
      expect(fakeService.lastFullScreen, isFalse);
      expect(fakeService.lastRegion, region);
      expect(fakeService.lastCountdownSeconds, 3);
    });

    // Gene - Nov, 13, 2026: Regression tests for multi-monitor full-screen recording region preservation, restart, and negative display Quartz coordinate parsing.
    test(
      'startFullScreenRecording forwards secondary displayRegion and preserves it across restartRecording',
      () async {
        const secondaryDisplay = Rect.fromLTWH(-1920, 0, 1920, 1080);
        final started = await controller.startFullScreenRecording(
          displayRegion: secondaryDisplay,
          countdownSeconds: 3,
        );
        expect(started, isTrue);
        expect(controller.isFullScreen, isTrue);
        expect(controller.activeRegion, secondaryDisplay);
        expect(fakeService.lastFullScreen, isTrue);
        expect(fakeService.lastRegion, secondaryDisplay);

        final restarted = await controller.restartRecording(countdownSeconds: 3);
        expect(restarted, isTrue);
        expect(fakeService.cancelCalls, 1);
        expect(fakeService.lastFullScreen, isTrue);
        expect(fakeService.lastRegion, secondaryDisplay);
      },
    );

    test(
      'OverlayRecordRequest.tryParse parses negative secondary-monitor fullScreen bounds',
      () {
        final req = OverlayRecordRequest.tryParse(
          'record:-1920.0:0.0:1920.0:1080.0:60:1:1:1:1:1:mic_usb',
        );
        expect(req, isNotNull);
        expect(req!.x, -1920.0);
        expect(req.y, 0.0);
        expect(req.width, 1920.0);
        expect(req.height, 1080.0);
        expect(req.fps, 60);
        expect(req.fullScreen, isTrue);
        expect(req.microphoneDeviceId, 'mic_usb');
      },
    );

    // Gene - Nov, 13, 2026: Verify native onRecordingStopped with null or error payload resets recording state and notifies onRecordingFailed.
    test(
      'native onRecordingStopped with null or error payload resets recording state and invokes onRecordingFailed',
      () async {
        final tempDir = Directory.systemTemp.createTempSync(
          'snipsnap_ctrl_native_stop',
        );
        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });
        const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathChannel, (call) async => tempDir.path);
        const channel = MethodChannel('snipsnap/capture');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'startScreenRecording') return true;
          return null;
        });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(pathChannel, null);
        });

        final failedMessages = <String?>[];
        final realService = CaptureService();
        final realController = ScreenRecordingController(
          captureService: realService,
          onRecordingFailed: failedMessages.add,
        );
        addTearDown(realController.dispose);

        await realController.startFullScreenRecording();
        expect(realController.isRecording, isTrue);

        Future<void> dispatchNativeStop(dynamic args) async {
          final bytes = const StandardMethodCodec().encodeMethodCall(
            MethodCall('onRecordingStopped', args),
          );
          await TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .handlePlatformMessage('snipsnap/capture', bytes, (_) {});
        }

        await dispatchNativeStop(null);
        expect(realController.isRecording, isFalse);
        expect(realController.state, ScreenRecordingState.idle);
        expect(failedMessages, [null]);

        await realController.startFullScreenRecording();
        expect(realController.isRecording, isTrue);

        await dispatchNativeStop(<String, dynamic>{'error': 'Failed'});
        expect(realController.isRecording, isFalse);
        expect(realController.state, ScreenRecordingState.idle);
        expect(failedMessages, [null, 'Failed']);
      },
    );
  });
}
