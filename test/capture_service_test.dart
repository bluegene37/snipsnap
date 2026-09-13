import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/services/capture_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The capture flows below assert on the `snipsnap/capture` method channel,
  // which only the macOS branch of CaptureService uses. On Windows and Linux
  // the service shells out to real OS tools (PowerShell / gnome-screenshot),
  // so on those hosts the tests would launch actual capture UIs and hang.
  final skipOffMacOS = Platform.isMacOS
      ? null
      : 'CaptureService only routes through the native channel on macOS';

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
    skip: skipOffMacOS,
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
    skip: skipOffMacOS,
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
    skip: skipOffMacOS,
  );

  group('hasScreenCapturePermission', () {
    // Regression for the "asks for Screen Recording on every screenshot"
    // report: with the grant missing, the old code requested the system
    // prompt inside the preflight call, so every capture put the dialog back
    // on screen. It must now preflight every time but request only once per
    // launch.
    bool authorized = false;

    setUp(() {
      authorized = false;
      CaptureService.resetScreenCapturePromptForTesting();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('snipsnap/capture'), (
            MethodCall call,
          ) async {
            methodCalls.add(call);
            switch (call.method) {
              case 'screenCaptureAuthorized':
                return authorized;
              case 'requestScreenCaptureAccess':
                // The real call returns false until the app is relaunched.
                return false;
            }
            return null;
          });
    });

    test('granted: returns true and never requests', () async {
      authorized = true;

      expect(await captureService.hasScreenCapturePermission(), isTrue);
      expect(await captureService.hasScreenCapturePermission(), isTrue);

      expect(methodCalls.map((c) => c.method), [
        'screenCaptureAuthorized',
        'screenCaptureAuthorized',
      ]);
    }, skip: skipOffMacOS);

    test(
      'missing: requests the prompt once per launch, not per capture',
      () async {
        for (var i = 0; i < 3; i++) {
          expect(await captureService.hasScreenCapturePermission(), isFalse);
        }

        final requests = methodCalls
            .where((c) => c.method == 'requestScreenCaptureAccess')
            .length;
        final preflights = methodCalls
            .where((c) => c.method == 'screenCaptureAuthorized')
            .length;
        expect(requests, 1, reason: 'the system prompt must not repeat');
        expect(preflights, 3, reason: 'each capture still re-checks the grant');
      },
      skip: skipOffMacOS,
    );

    test('missing: a second service instance does not re-prompt', () async {
      await captureService.hasScreenCapturePermission();
      await CaptureService().hasScreenCapturePermission();

      expect(
        methodCalls.where((c) => c.method == 'requestScreenCaptureAccess'),
        hasLength(1),
      );
    }, skip: skipOffMacOS);

    test(
      'preflight only: a granted check never calls the request method',
      () async {
        authorized = true;
        await captureService.hasScreenCapturePermission();
        authorized = false;
        await captureService.hasScreenCapturePermission();
        authorized = true;
        await captureService.hasScreenCapturePermission();

        expect(
          methodCalls.where((c) => c.method == 'requestScreenCaptureAccess'),
          hasLength(1),
        );
      },
      skip: skipOffMacOS,
    );
  });

  test('importImage copies external image into storage directory', () async {
    final sourceFile = File('${tempDir.path}/external.png');
    await sourceFile.writeAsBytes([10, 20, 30, 40]);

    final result = await captureService.importImage(sourceFile.path);

    expect(result, isNotNull);
    expect(File(result!).existsSync(), isTrue);
    expect(await File(result).readAsBytes(), [10, 20, 30, 40]);
  });
}
