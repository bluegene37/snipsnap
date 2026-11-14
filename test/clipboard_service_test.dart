// Gene - Nov, 14, 2026: Added unit and MethodChannel tests for ClipboardService.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/services/clipboard_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const captureChannel = MethodChannel('snipsnap/capture');
  final skipWithoutNativeChannel = (Platform.isMacOS || Platform.isWindows)
      ? null
      : 'ClipboardService native channel branches run on macOS and Windows';

  late Directory tempDir;
  late List<MethodCall> captureCalls;
  late List<MethodCall> platformCalls;

  void setCaptureMock(Future<Object?>? Function(MethodCall call)? handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(captureChannel, handler);
  }

  void setPlatformMock(Future<Object?>? Function(MethodCall call)? handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, handler);
  }

  setUp(() async {
    captureCalls = <MethodCall>[];
    platformCalls = <MethodCall>[];
    tempDir = await Directory.systemTemp.createTemp('snipsnap_clipboard_test');

    setPlatformMock((MethodCall call) async {
      platformCalls.add(call);
      return null;
    });
  });

  tearDown(() async {
    setCaptureMock(null);
    setPlatformMock(null);
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('copyImageBytesToClipboard', () {
    final pngBytes = Uint8List.fromList(<int>[137, 80, 78, 71, 13, 10, 26, 10]);

    test(
      'returns true and sends bytes payload when native channel succeeds',
      () async {
        setCaptureMock((MethodCall call) async {
          captureCalls.add(call);
          return true;
        });

        final ok = await ClipboardService.copyImageBytesToClipboard(pngBytes);

        expect(ok, isTrue);
        expect(captureCalls, hasLength(1));
        expect(captureCalls.single.method, 'copyImageToClipboard');
        final args = captureCalls.single.arguments as Map<Object?, Object?>;
        expect(args['bytes'], pngBytes);
      },
      skip: skipWithoutNativeChannel,
    );

    test(
      'returns false when native channel returns false or null',
      () async {
        setCaptureMock((MethodCall call) async {
          captureCalls.add(call);
          return false;
        });
        expect(
          await ClipboardService.copyImageBytesToClipboard(pngBytes),
          isFalse,
        );

        setCaptureMock((MethodCall call) async {
          captureCalls.add(call);
          return null;
        });
        expect(
          await ClipboardService.copyImageBytesToClipboard(pngBytes),
          isFalse,
        );
        expect(captureCalls, hasLength(2));
      },
      skip: skipWithoutNativeChannel,
    );

    test(
      'returns false without throwing on MissingPluginException',
      () async {
        setCaptureMock(null);

        final ok = await ClipboardService.copyImageBytesToClipboard(pngBytes);

        expect(ok, isFalse);
      },
      skip: skipWithoutNativeChannel,
    );

    test(
      'returns false without throwing when native channel throws PlatformException',
      () async {
        setCaptureMock((MethodCall call) async {
          throw PlatformException(code: 'ERR', message: 'pasteboard busy');
        });

        final ok = await ClipboardService.copyImageBytesToClipboard(pngBytes);

        expect(ok, isFalse);
      },
      skip: skipWithoutNativeChannel,
    );
  });

  group('copyImageToClipboard', () {
    // Do NOT return null or throw MissingPluginException from `snipsnap/capture`
    // in these tests on macOS/Windows: ClipboardService falls through to
    // spawning `osascript` / `powershell`, which would mutate the host clipboard.
    test(
      'returns true and passes filePath when native channel succeeds',
      () async {
        const path = '/tmp/example_capture.png';
        setCaptureMock((MethodCall call) async {
          captureCalls.add(call);
          return true;
        });

        final ok = await ClipboardService.copyImageToClipboard(path);

        expect(ok, isTrue);
        expect(captureCalls, hasLength(1));
        expect(captureCalls.single.method, 'copyImageToClipboard');
        final args = captureCalls.single.arguments as Map<Object?, Object?>;
        expect(args['filePath'], path);
      },
      skip: skipWithoutNativeChannel,
    );

    test(
      'returns false without spawning fallback when native channel returns false',
      () async {
        setCaptureMock((MethodCall call) async {
          captureCalls.add(call);
          return false;
        });

        final ok = await ClipboardService.copyImageToClipboard(
          '/tmp/example_capture.png',
        );

        expect(ok, isFalse);
        expect(captureCalls, hasLength(1));
      },
      skip: skipWithoutNativeChannel,
    );

    test(
      'returns false without spawning fallback when native channel throws PlatformException',
      () async {
        setCaptureMock((MethodCall call) async {
          captureCalls.add(call);
          throw PlatformException(code: 'ERR', message: 'write failed');
        });

        final ok = await ClipboardService.copyImageToClipboard(
          '/tmp/example_capture.png',
        );

        expect(ok, isFalse);
        expect(captureCalls, hasLength(1));
      },
      skip: skipWithoutNativeChannel,
    );
  });

  group('copyText', () {
    test('writes text through Clipboard.setData on SystemChannels.platform', () async {
      await ClipboardService.copyText('Hello SnipSnap');

      expect(platformCalls, hasLength(1));
      expect(platformCalls.single.method, 'Clipboard.setData');
      final args = platformCalls.single.arguments as Map<Object?, Object?>;
      expect(args['text'], 'Hello SnipSnap');
    });
  });

  group('pasteImageFromClipboard', () {
    test(
      'returns savedPath when native channel writes a non-empty file',
      () async {
        final targetPath = '${tempDir.path}/pasted.png';
        setCaptureMock((MethodCall call) async {
          captureCalls.add(call);
          final args = call.arguments as Map<Object?, Object?>;
          final path = args['targetPath'] as String;
          await File(path).writeAsBytes(<int>[137, 80, 78, 71]);
          return path;
        });

        final saved = await ClipboardService.pasteImageFromClipboard(
          targetPath,
        );

        expect(saved, targetPath);
        expect(captureCalls, hasLength(1));
        expect(captureCalls.single.method, 'pasteImageFromClipboard');
      },
      skip: skipWithoutNativeChannel,
    );

    test(
      'returns null when native channel returns a path that does not exist',
      () async {
        final missingPath = '${tempDir.path}/missing.png';
        setCaptureMock((MethodCall call) async => missingPath);

        final saved = await ClipboardService.pasteImageFromClipboard(
          missingPath,
        );

        expect(saved, isNull);
      },
      skip: skipWithoutNativeChannel,
    );

    test(
      'returns null when native channel leaves an empty 0-byte file',
      () async {
        final emptyPath = '${tempDir.path}/empty.png';
        setCaptureMock((MethodCall call) async {
          await File(emptyPath).writeAsBytes(<int>[]);
          return emptyPath;
        });

        final saved = await ClipboardService.pasteImageFromClipboard(emptyPath);

        expect(saved, isNull);
      },
      skip: skipWithoutNativeChannel,
    );

    test(
      'returns null when native channel returns null',
      () async {
        setCaptureMock((MethodCall call) async => null);

        final saved = await ClipboardService.pasteImageFromClipboard(
          '${tempDir.path}/none.png',
        );

        expect(saved, isNull);
      },
      skip: skipWithoutNativeChannel,
    );

    test(
      'returns null without throwing on MissingPluginException and PlatformException',
      () async {
        final targetPath = '${tempDir.path}/error.png';
        setCaptureMock(null);
        expect(
          await ClipboardService.pasteImageFromClipboard(targetPath),
          isNull,
        );

        setCaptureMock((MethodCall call) async {
          throw PlatformException(code: 'ERR', message: 'read error');
        });
        expect(
          await ClipboardService.pasteImageFromClipboard(targetPath),
          isNull,
        );
      },
      skip: skipWithoutNativeChannel,
    );
  });

  group('copyFileToClipboard', () {
    test(
      'returns true via native channel without overwriting clipboard with plain text',
      () async {
        const videoPath = '/tmp/recording.mp4';
        setCaptureMock((MethodCall call) async {
          captureCalls.add(call);
          return true;
        });

        final ok = await ClipboardService.copyFileToClipboard(videoPath);

        expect(ok, isTrue);
        expect(captureCalls, hasLength(1));
        expect(captureCalls.single.method, 'copyFileToClipboard');
        final args = captureCalls.single.arguments as Map<Object?, Object?>;
        expect(args['filePath'], videoPath);
        expect(platformCalls, isEmpty);
      },
      skip: skipWithoutNativeChannel,
    );

    test(
      'falls back to Clipboard.setData with file path when native channel returns false or null',
      () async {
        const videoPath = '/tmp/recording.mp4';
        setCaptureMock((MethodCall call) async {
          captureCalls.add(call);
          return false;
        });

        expect(await ClipboardService.copyFileToClipboard(videoPath), isTrue);
        expect(platformCalls, hasLength(1));
        expect(platformCalls.single.method, 'Clipboard.setData');
        expect(
          (platformCalls.single.arguments as Map<Object?, Object?>)['text'],
          videoPath,
        );

        setCaptureMock((MethodCall call) async {
          captureCalls.add(call);
          return null;
        });

        expect(await ClipboardService.copyFileToClipboard(videoPath), isTrue);
        expect(platformCalls, hasLength(2));
      },
      skip: skipWithoutNativeChannel,
    );

    test(
      'returns false when capture channel or platform clipboard throws PlatformException',
      () async {
        const videoPath = '/tmp/recording.mp4';
        setCaptureMock((MethodCall call) async {
          throw PlatformException(code: 'ERR', message: 'native error');
        });
        if (Platform.isMacOS || Platform.isWindows) {
          expect(
            await ClipboardService.copyFileToClipboard(videoPath),
            isFalse,
          );
        }

        setCaptureMock((MethodCall call) async => false);
        setPlatformMock((MethodCall call) async {
          throw PlatformException(code: 'ERR', message: 'clipboard error');
        });
        expect(await ClipboardService.copyFileToClipboard(videoPath), isFalse);
      },
    );
  });
}
