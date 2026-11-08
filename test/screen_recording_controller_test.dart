// Gene - Nov, 08, 2026: Unit tests for ScreenRecordingController and ScreenRecordingResult.
import 'package:flutter/painting.dart';
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

  @override
  Future<String> generateNewMediaPath({
    String prefix = 'snip',
    String extension = 'png',
  }) async {
    return '/tmp/${prefix}_mock.$extension';
  }

  @override
  Future<bool> startScreenRecording({
    required String targetPath,
    required String thumbnailPath,
    bool fullScreen = true,
    Rect? region,
    int fps = 30,
    bool recordAudio = false,
  }) async {
    lastFullScreen = fullScreen;
    lastRegion = region;
    lastRecordAudio = recordAudio;
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
  });
}
