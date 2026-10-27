// test/scrolling/native_scroll_service_test.dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/services/capture_service.dart';
import 'package:snipsnap/services/scrolling/native_scroll_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NativeScrollService', () {
    late NativeScrollService service;
    final List<MethodCall> log = [];

    setUp(() {
      service = PlatformNativeScrollService();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('snipsnap/capture'), (
            call,
          ) async {
            log.add(call);
            if (call.method == 'captureRect') {
              return Uint8List.fromList([
                137,
                80,
                78,
                71,
              ]); // mock PNG magic bytes
            }
            if (call.method == 'simulateScroll') {
              return true;
            }
            return null;
          });
      log.clear();
    });

    test('captureRectBytes scales coordinates by devicePixelRatio', () async {
      final bytes = await service.captureRectBytes(
        const Rect.fromLTWH(10, 20, 300, 200),
        devicePixelRatio: 2.0,
      );

      expect(bytes, isNotNull);
      expect(log.length, 1);
      expect(log.first.method, 'captureRect');
      final args = log.first.arguments as Map;
      expect(args['x'], 20.0);
      expect(args['y'], 40.0);
      expect(args['width'], 600.0);
      expect(args['height'], 400.0);
    });

    test(
      'simulateScrollWheel invokes simulateScroll with correct arguments',
      () async {
        await service.simulateScrollWheel(
          deltaY: 120,
          position: const Offset(150, 250),
        );

        expect(log.length, 1);
        expect(log.first.method, 'simulateScroll');
        final args = log.first.arguments as Map;
        expect(args['deltaY'], 120);
        expect(args['x'], 150.0);
        expect(args['y'], 250.0);
      },
    );

    test(
      'captureRectBytes handles platform exception gracefully and returns null',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(const MethodChannel('snipsnap/capture'), (
              call,
            ) async {
              throw PlatformException(code: 'error', message: 'Capture failed');
            });

        final bytes = await service.captureRectBytes(
          const Rect.fromLTWH(0, 0, 100, 100),
        );
        expect(bytes, isNull);
      },
    );

    test(
      'simulateScrollWheel handles exception gracefully without throwing',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(const MethodChannel('snipsnap/capture'), (
              call,
            ) async {
              throw PlatformException(
                code: 'error',
                message: 'Simulate scroll failed',
              );
            });

        // Should complete without unhandled exception
        await service.simulateScrollWheel(
          deltaY: 100,
          position: const Offset(50, 50),
        );
      },
    );
  });

  group('CaptureService.captureRectBytes', () {
    final List<MethodCall> log = [];

    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('snipsnap/capture'), (
            call,
          ) async {
            log.add(call);
            if (call.method == 'captureRect') {
              return Uint8List.fromList([137, 80, 78, 71]);
            }
            return null;
          });
      log.clear();
    });

    test(
      'captureRectBytes invokes channel with scaled rect coordinates',
      () async {
        final captureService = CaptureService();
        final bytes = await captureService.captureRectBytes(
          const Rect.fromLTWH(15, 25, 400, 300),
          devicePixelRatio: 1.5,
        );

        expect(bytes, isNotNull);
        expect(log.length, 1);
        expect(log.first.method, 'captureRect');
        final args = log.first.arguments as Map;
        expect(args['x'], 22.5);
        expect(args['y'], 37.5);
        expect(args['width'], 600.0);
        expect(args['height'], 450.0);
      },
    );
  });
}
