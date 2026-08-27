import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/services/capture_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CaptureService captureService;
  late Directory tempDir;
  final List<MethodCall> methodCalls = [];
  String? mockCaptureResult;

  setUp(() async {
    methodCalls.clear();
    mockCaptureResult = null;
    tempDir = await Directory.systemTemp.createTemp('snipsnap_capture_test');
    captureService = CaptureService();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall call) async {
            return tempDir.path;
          },
        );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('snipsnap/capture'), (
          MethodCall call,
        ) async {
          methodCalls.add(call);
          if (call.method == 'captureInteractive' ||
              call.method == 'captureFullScreen') {
            if (mockCaptureResult != null) {
              // Create a fake dummy image file at target path if requested
              final args = call.arguments as Map<dynamic, dynamic>?;
              final targetPath = args?['targetPath'] as String?;
              if (targetPath != null) {
                final file = File(targetPath);
                await file.parent.create(recursive: true);
                await file.writeAsBytes([1, 2, 3, 4]); // Fake bytes
                return targetPath;
              }
            }
            // Returns null when user cancelled or pressed any key
            return null;
          }
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('snipsnap/capture'),
          null,
        );
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'captureInteractive invokes native channel and returns path on success',
    () async {
      mockCaptureResult = 'success';
      final result = await captureService.captureInteractive();

      expect(result, isNotNull);
      expect(File(result!).existsSync(), isTrue);
      expect(methodCalls.length, 1);
      expect(methodCalls.first.method, 'captureInteractive');
      expect(methodCalls.first.arguments, isA<Map<dynamic, dynamic>>());
    },
  );

  test(
    'captureInteractive returns null when user presses any key to escape/cancel',
    () async {
      mockCaptureResult = null; // Channel returns null
      final result = await captureService.captureInteractive();

      expect(result, isNull);
      expect(methodCalls.length, 1);
      expect(methodCalls.first.method, 'captureInteractive');
    },
  );

  test(
    'captureFullScreen invokes native channel and returns path on success',
    () async {
      mockCaptureResult = 'success';
      final result = await captureService.captureFullScreen();

      expect(result, isNotNull);
      expect(File(result!).existsSync(), isTrue);
      expect(methodCalls.length, 1);
      expect(methodCalls.first.method, 'captureFullScreen');
    },
  );

  test('importImage copies external image into storage directory', () async {
    final sourceFile = File('${tempDir.path}/external.png');
    await sourceFile.writeAsBytes([10, 20, 30, 40]);

    final result = await captureService.importImage(sourceFile.path);

    expect(result, isNotNull);
    expect(File(result!).existsSync(), isTrue);
    expect(await File(result).readAsBytes(), [10, 20, 30, 40]);
  });
}
