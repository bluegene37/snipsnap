// Gene - Oct, 27, 2026: Unit tests for ScrollingCaptureController state lifecycle and panoramic frame stitching (Task 3).
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:snipsnap/services/scrolling/image_stitcher.dart';
import 'package:snipsnap/services/scrolling/native_scroll_service.dart';
import 'package:snipsnap/services/scrolling/scrolling_capture_controller.dart';

class FakeNativeScrollService implements NativeScrollService {
  final List<Uint8List?> Function()? byteSequence;
  int callCount = 0;
  List<Uint8List?> _frames = [];

  FakeNativeScrollService({this.byteSequence}) {
    if (byteSequence != null) {
      _frames = byteSequence!();
    }
  }

  void setFrames(List<Uint8List?> frames) {
    _frames = frames;
    callCount = 0;
  }

  @override
  Future<Uint8List?> captureRectBytes(
    Rect rect, {
    double devicePixelRatio = 1.0,
  }) async {
    if (_frames.isNotEmpty) {
      final index = callCount < _frames.length ? callCount : _frames.length - 1;
      callCount++;
      return _frames[index];
    }
    callCount++;
    final image = img.Image(width: 100, height: 100);
    img.fill(image, color: img.ColorRgb8(callCount * 10, 50, 100));
    return Uint8List.fromList(img.encodePng(image));
  }

  @override
  Future<void> simulateScrollWheel({
    required int deltaY,
    required Offset position,
  }) async {}
}

img.Image createPatternImage(int width, int height, {int offsetY = 0}) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    final globalY = y + offsetY;
    final color = img.ColorRgb8(
      (globalY * 7) % 256,
      (globalY * 13) % 256,
      (globalY * 17) % 256,
    );
    for (var x = 0; x < width; x++) {
      image.setPixel(x, y, color);
    }
  }
  return image;
}

Uint8List createPatternPngBytes(int width, int height, {int offsetY = 0}) {
  final image = createPatternImage(width, height, offsetY: offsetY);
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('snipsnap_scroll_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall call) async {
            return tempDir.path;
          },
        );
  });

  tearDown(() async {
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('ScrollingCaptureController Lifecycle', () {
    test(
      'ScrollingCaptureController transitions through lifecycle states',
      () async {
        final fakeScroll = FakeNativeScrollService();
        final controller = ScrollingCaptureController(
          nativeService: fakeScroll,
          storageDirectoryProvider: () async => tempDir,
        );

        expect(controller.status, ScrollingCaptureStatus.idle);
        expect(controller.cumulativeHeight, 0);
        expect(controller.frameCount, 0);
        expect(controller.lastSavedPath, isNull);

        await controller.startCapture(
          viewportRect: const Rect.fromLTWH(0, 0, 100, 100),
          devicePixelRatio: 1.0,
          samplingInterval: const Duration(milliseconds: 50),
        );
        expect(controller.status, ScrollingCaptureStatus.capturing);
        expect(controller.frameCount, 1);
        expect(controller.cumulativeHeight, 100);

        controller.pauseCapture();
        expect(controller.status, ScrollingCaptureStatus.paused);

        controller.resumeCapture();
        expect(controller.status, ScrollingCaptureStatus.capturing);

        controller.cancelCapture();
        expect(controller.status, ScrollingCaptureStatus.cancelled);
        controller.dispose();
      },
    );

    test('cancels capture when initial frame capture returns null', () async {
      final fakeScroll = FakeNativeScrollService();
      fakeScroll.setFrames([null]);
      final controller = ScrollingCaptureController(
        nativeService: fakeScroll,
        storageDirectoryProvider: () async => tempDir,
      );

      await controller.startCapture(
        viewportRect: const Rect.fromLTWH(0, 0, 100, 100),
        devicePixelRatio: 1.0,
      );

      expect(controller.status, ScrollingCaptureStatus.cancelled);
      expect(controller.frameCount, 0);
      expect(controller.cumulativeHeight, 0);
      controller.dispose();
    });

    test(
      'samples and stitches vertical scrolling frames into composite',
      () async {
        final frame1 = createPatternPngBytes(100, 100, offsetY: 0);
        final frame2 = createPatternPngBytes(100, 100, offsetY: 30);
        final frame3 = createPatternPngBytes(100, 100, offsetY: 60);

        final fakeScroll = FakeNativeScrollService();
        fakeScroll.setFrames([frame1, frame2, frame3]);

        final controller = ScrollingCaptureController(
          nativeService: fakeScroll,
          stitcher: ImageStitcher(
            scrollbarIgnoreMargin: 5,
            maxMatchError: 30.0,
          ),
          storageDirectoryProvider: () async => tempDir,
        );

        await controller.startCapture(
          viewportRect: const Rect.fromLTWH(0, 0, 100, 100),
          devicePixelRatio: 1.0,
          samplingInterval: const Duration(milliseconds: 25),
        );

        expect(controller.frameCount, 1);
        expect(controller.cumulativeHeight, 100);

        // Wait for two sampling intervals to process frames 2 and 3
        await Future<void>.delayed(const Duration(milliseconds: 90));

        expect(controller.frameCount, greaterThanOrEqualTo(2));
        expect(controller.cumulativeHeight, greaterThan(100));

        final savedPath = await controller.finishCapture();
        expect(savedPath, isNotNull);
        expect(controller.status, ScrollingCaptureStatus.completed);
        expect(controller.lastSavedPath, equals(savedPath));

        final file = File(savedPath!);
        expect(await file.exists(), isTrue);
        final savedBytes = await file.readAsBytes();
        final decoded = img.decodePng(savedBytes);
        expect(decoded, isNotNull);
        expect(decoded!.height, equals(controller.cumulativeHeight));
        controller.dispose();
      },
    );

    test('ignores stationary / duplicate frames during sampling', () async {
      final frame1 = createPatternPngBytes(100, 100, offsetY: 0);
      final duplicateFrame = createPatternPngBytes(100, 100, offsetY: 0);

      final fakeScroll = FakeNativeScrollService();
      fakeScroll.setFrames([frame1, duplicateFrame, duplicateFrame]);

      final controller = ScrollingCaptureController(
        nativeService: fakeScroll,
        stitcher: ImageStitcher(scrollbarIgnoreMargin: 5, maxMatchError: 30.0),
        storageDirectoryProvider: () async => tempDir,
      );

      await controller.startCapture(
        viewportRect: const Rect.fromLTWH(0, 0, 100, 100),
        devicePixelRatio: 1.0,
        samplingInterval: const Duration(milliseconds: 25),
      );

      expect(controller.frameCount, 1);
      expect(controller.cumulativeHeight, 100);

      await Future<void>.delayed(const Duration(milliseconds: 70));

      // Cumulative height and frameCount should remain stationary
      expect(controller.frameCount, 1);
      expect(controller.cumulativeHeight, 100);

      controller.cancelCapture();
      controller.dispose();
    });

    test('pausing capture skips sampling until resumed', () async {
      final frame1 = createPatternPngBytes(100, 100, offsetY: 0);
      final frame2 = createPatternPngBytes(100, 100, offsetY: 30);

      final fakeScroll = FakeNativeScrollService();
      fakeScroll.setFrames([frame1, frame2]);

      final controller = ScrollingCaptureController(
        nativeService: fakeScroll,
        stitcher: ImageStitcher(scrollbarIgnoreMargin: 5, maxMatchError: 30.0),
        storageDirectoryProvider: () async => tempDir,
      );

      await controller.startCapture(
        viewportRect: const Rect.fromLTWH(0, 0, 100, 100),
        devicePixelRatio: 1.0,
        samplingInterval: const Duration(milliseconds: 30),
      );

      controller.pauseCapture();
      expect(controller.status, ScrollingCaptureStatus.paused);
      final callCountWhilePaused = fakeScroll.callCount;

      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(fakeScroll.callCount, equals(callCountWhilePaused));
      expect(controller.cumulativeHeight, 100);

      controller.resumeCapture();
      expect(controller.status, ScrollingCaptureStatus.capturing);

      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(fakeScroll.callCount, greaterThan(callCountWhilePaused));

      controller.cancelCapture();
      controller.dispose();
    });

    test(
      'finishCapture returns null if capture was cancelled or idle',
      () async {
        final controller = ScrollingCaptureController(
          storageDirectoryProvider: () async => tempDir,
        );

        final result = await controller.finishCapture();
        expect(result, isNull);
        expect(controller.status, ScrollingCaptureStatus.cancelled);
        controller.dispose();
      },
    );

    test('cancelCapture clears composite and cancels timer', () async {
      final frame1 = createPatternPngBytes(100, 100, offsetY: 0);
      final fakeScroll = FakeNativeScrollService();
      fakeScroll.setFrames([frame1]);

      final controller = ScrollingCaptureController(
        nativeService: fakeScroll,
        storageDirectoryProvider: () async => tempDir,
      );

      await controller.startCapture(
        viewportRect: const Rect.fromLTWH(0, 0, 100, 100),
        devicePixelRatio: 1.0,
      );

      expect(controller.status, ScrollingCaptureStatus.capturing);
      controller.cancelCapture();

      expect(controller.status, ScrollingCaptureStatus.cancelled);
      expect(controller.cumulativeHeight, 0);

      final finishResult = await controller.finishCapture();
      expect(finishResult, isNull);
      controller.dispose();
    });
  });
}
