// Gene - Nov, 24, 2026: Tests covering Windows hotkey registration, reserved chord checks, storage dir cache, desktop known folder resolution, save-dialog cancel behavior, and recording restart/cancel restoreWindow flags.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:snipsnap/models/app_shortcut.dart';
import 'package:snipsnap/services/capture_service.dart';
import 'package:snipsnap/services/screen_recording_controller.dart';
import 'package:snipsnap/services/shortcut_service.dart';
import 'package:snipsnap/services/storage_service.dart';

class _TrackingCaptureService extends CaptureService {
  final List<bool> cancelRestoreFlags = <bool>[];
  bool startResult = true;

  @override
  Future<String> generateNewMediaPath({
    String prefix = 'snip',
    String extension = 'png',
  }) async {
    return '/tmp/${prefix}_win_test.$extension';
  }

  @override
  Future<String> generateNewThumbnailPath({String prefix = 'rec_thumb'}) async {
    return '/tmp/.thumbnails/${prefix}_win_test.png';
  }

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
    return startResult;
  }

  @override
  Future<void> cancelScreenRecording({bool restoreWindow = true}) async {
    cancelRestoreFlags.add(restoreWindow);
  }
}

CustomShortcut _winShortcut(
  LogicalKeyboardKey key, {
  bool meta = false,
  bool ctrl = false,
  bool shift = false,
  bool alt = false,
  AppShortcutAction action = AppShortcutAction.interactiveSnip,
}) {
  return CustomShortcut(
    action: action,
    keyId: key.keyId,
    keyLabel: key.keyLabel,
    meta: meta,
    ctrl: ctrl,
    shift: shift,
    alt: alt,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const captureChannel = MethodChannel('snipsnap/capture');
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  late Directory tempDir;
  late List<MethodCall> captureCalls;

  setUp(() async {
    captureCalls = <MethodCall>[];
    tempDir = await Directory.systemTemp.createTemp('snipsnap_win_enh_test');
  });

  tearDown(() async {
    ShortcutService.debugIsWindowsOverride = null;
    ShortcutService.debugIsMacOSOverride = null;
    CaptureService.debugIsWindowsOverride = null;
    StorageService.debugSaveFileOverride = null;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(captureChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);

    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('ShortcutService Windows helpers & native hotkeys', () {
    test('isReservedBySystem blocks Windows OS-reserved chords only', () {
      ShortcutService.debugIsWindowsOverride = true;
      ShortcutService.debugIsMacOSOverride = false;

      expect(
        ShortcutService.isReservedBySystem(
          _winShortcut(LogicalKeyboardKey.keyS, meta: true, shift: true),
        ),
        isTrue,
      );
      for (final key in [
        LogicalKeyboardKey.keyL,
        LogicalKeyboardKey.keyD,
        LogicalKeyboardKey.keyE,
        LogicalKeyboardKey.keyR,
        LogicalKeyboardKey.keyV,
        LogicalKeyboardKey.keyG,
        LogicalKeyboardKey.tab,
      ]) {
        expect(
          ShortcutService.isReservedBySystem(_winShortcut(key, meta: true)),
          isTrue,
          reason: 'Win+${key.keyLabel} is reserved by Windows',
        );
      }
      expect(
        ShortcutService.isReservedBySystem(
          _winShortcut(LogicalKeyboardKey.f4, alt: true),
        ),
        isTrue,
      );
      expect(
        ShortcutService.isReservedBySystem(
          _winShortcut(LogicalKeyboardKey.delete, ctrl: true, alt: true),
        ),
        isTrue,
      );
      expect(
        ShortcutService.isReservedBySystem(
          _winShortcut(LogicalKeyboardKey.escape, ctrl: true, shift: true),
        ),
        isTrue,
      );

      // Safe user chords must be allowed.
      expect(
        ShortcutService.isReservedBySystem(
          _winShortcut(LogicalKeyboardKey.keyX, ctrl: true, shift: true),
        ),
        isFalse,
      );
      expect(
        ShortcutService.isReservedBySystem(
          _winShortcut(LogicalKeyboardKey.digit2, ctrl: true, shift: true),
        ),
        isFalse,
      );
      expect(
        ShortcutService.isReservedBySystem(
          _winShortcut(LogicalKeyboardKey.keyS, ctrl: true, alt: true),
        ),
        isFalse,
      );
    });

    test(
      'logicalKeyToWindowsVk & modifiersToWindowsMask translate accurately',
      () {
        expect(
          ShortcutService.logicalKeyToWindowsVk(LogicalKeyboardKey.keyA),
          0x41,
        );
        expect(
          ShortcutService.logicalKeyToWindowsVk(LogicalKeyboardKey.keyX),
          0x58,
        );
        expect(
          ShortcutService.logicalKeyToWindowsVk(LogicalKeyboardKey.digit0),
          0x30,
        );
        expect(
          ShortcutService.logicalKeyToWindowsVk(LogicalKeyboardKey.digit9),
          0x39,
        );
        expect(
          ShortcutService.logicalKeyToWindowsVk(LogicalKeyboardKey.f1),
          0x70,
        );
        expect(
          ShortcutService.logicalKeyToWindowsVk(LogicalKeyboardKey.f12),
          0x7B,
        );
        expect(
          ShortcutService.logicalKeyToWindowsVk(LogicalKeyboardKey.printScreen),
          0x2C,
        );
        expect(
          ShortcutService.logicalKeyToWindowsVk(LogicalKeyboardKey.space),
          0x20,
        );
        expect(
          ShortcutService.logicalKeyToWindowsVk(LogicalKeyboardKey.escape),
          0x1B,
        );
        expect(
          ShortcutService.logicalKeyToWindowsVk(LogicalKeyboardKey.delete),
          0x2E,
        );
        expect(
          ShortcutService.logicalKeyToWindowsVk(LogicalKeyboardKey.numpad5),
          0x65,
        );

        expect(
          ShortcutService.modifiersToWindowsMask(
            _winShortcut(LogicalKeyboardKey.keyA, alt: true),
          ),
          0x0001,
        );
        expect(
          ShortcutService.modifiersToWindowsMask(
            _winShortcut(LogicalKeyboardKey.keyA, ctrl: true),
          ),
          0x0002,
        );
        expect(
          ShortcutService.modifiersToWindowsMask(
            _winShortcut(LogicalKeyboardKey.keyA, shift: true),
          ),
          0x0004,
        );
        expect(
          ShortcutService.modifiersToWindowsMask(
            _winShortcut(LogicalKeyboardKey.keyA, meta: true),
          ),
          0x0008,
        );
        expect(
          ShortcutService.modifiersToWindowsMask(
            _winShortcut(LogicalKeyboardKey.keyA, ctrl: true, shift: true),
          ),
          0x0006,
        );
      },
    );

    test(
      'registerGlobalHotKeys on Windows uses native snipsnap/capture and handles callbacks',
      () async {
        ShortcutService.debugIsWindowsOverride = true;
        ShortcutService.debugIsMacOSOverride = false;
        CaptureService.debugIsWindowsOverride = true;

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(captureChannel, (MethodCall call) async {
              captureCalls.add(call);
              if (call.method == 'registerWindowsHotKeys') {
                return <String>['fullScreenSnip'];
              }
              return true;
            });

        final triggered = <AppShortcutAction>[];
        final failed = await ShortcutService.registerGlobalHotKeys(
          shortcuts: ShortcutService.getDefaultShortcuts(),
          onHotKeyTriggered: triggered.add,
        );

        expect(failed, {AppShortcutAction.fullScreenSnip});
        expect(captureCalls.length, 1);
        expect(captureCalls.first.method, 'registerWindowsHotKeys');
        final entries =
            (captureCalls.first.arguments as Map<dynamic, dynamic>)['entries']
                as List<dynamic>;
        expect(entries.length, 6);

        final encoded = const StandardMethodCodec().encodeMethodCall(
          const MethodCall('onGlobalHotKey', {'action': 'interactiveSnip'}),
        );
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage('snipsnap/capture', encoded, (_) {});
        expect(triggered, [AppShortcutAction.interactiveSnip]);

        await ShortcutService.unregisterGlobalHotKeys();
        expect(
          captureCalls.any((c) => c.method == 'unregisterWindowsHotKeys'),
          isTrue,
        );
      },
    );
  });

  group('CaptureService Windows methods & storage cache', () {
    test(
      'getStorageDirectory returns cached dir without repeated disk checks',
      () async {
        var pathProviderCalls = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProviderChannel, (
              MethodCall call,
            ) async {
              pathProviderCalls++;
              return tempDir.path;
            });

        final service = CaptureService();
        final first = await service.getStorageDirectory();
        expect(pathProviderCalls, 1);
        expect(first.existsSync(), isTrue);

        await first.delete(recursive: true);
        expect(first.existsSync(), isFalse);

        // Cached Directory returns directly with zero extra path_provider calls.
        final second = await service.getStorageDirectory();
        expect(second.path, first.path);
        expect(pathProviderCalls, 1);

        service.invalidateStorageDirCache();
        final third = await service.getStorageDirectory();
        expect(pathProviderCalls, 2);
        expect(third.existsSync(), isTrue);
      },
    );

    test('Windows helper methods invoke expected channel calls', () async {
      CaptureService.debugIsWindowsOverride = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(captureChannel, (MethodCall call) async {
            captureCalls.add(call);
            if (call.method == 'getKnownDesktopPath') {
              return r'C:\Users\Demo\OneDrive\Desktop';
            }
            return true;
          });

      final service = CaptureService();
      await service.cancelScreenRecording(restoreWindow: false);
      await service.releaseVideoPlayersForPath(r'C:\Videos\clip.mp4');
      await service.setWindowTheme(darkMode: true);
      final desktop = await service.getKnownDesktopPath();
      await service.setCloseToTray(false);

      expect(desktop, r'C:\Users\Demo\OneDrive\Desktop');
      expect(captureCalls[0].method, 'cancelScreenRecording');
      expect(captureCalls[0].arguments, {'restoreWindow': false});
      expect(captureCalls[1].method, 'releaseVideoPlayersForPath');
      expect(captureCalls[1].arguments, {'filePath': r'C:\Videos\clip.mp4'});
      expect(captureCalls[2].method, 'setWindowTheme');
      expect(captureCalls[2].arguments, {'darkMode': true});
      expect(captureCalls[3].method, 'getKnownDesktopPath');
      expect(captureCalls[4].method, 'setCloseToTray');
      expect(captureCalls[4].arguments, {'enabled': false});
    });
  });

  group('ScreenRecordingController restart vs cancel restoreWindow', () {
    test(
      'restartRecording passes restoreWindow=false while cancelRecording passes true',
      () async {
        final fakeService = _TrackingCaptureService();
        final controller = ScreenRecordingController(
          captureService: fakeService,
        );
        addTearDown(controller.dispose);

        expect(
          await controller.startAreaRecording(
            const Rect.fromLTWH(0, 0, 200, 120),
          ),
          isTrue,
        );
        expect(await controller.restartRecording(countdownSeconds: 0), isTrue);
        await controller.cancelRecording();

        expect(fakeService.cancelRestoreFlags, [false, true]);
      },
    );
  });

  group('StorageService Save As cancel & Windows Desktop preset', () {
    test(
      'exportImageDialogWithFormat returns null on user cancel without falling back',
      () async {
        StorageService.debugSaveFileOverride =
            ({
              required String fileName,
              required Uint8List bytes,
              String? dialogTitle,
            }) async => null;

        final saved = await StorageService.exportImageDialogWithFormat(
          bytes: [1, 2, 3, 4],
          fileName: 'cancelled_export',
          isJpg: false,
        );
        expect(saved, isNull);
      },
    );

    test(
      'desktop preset uses Windows Known Folder Desktop path when present',
      () async {
        CaptureService.debugIsWindowsOverride = true;
        final fakeDesktop = Directory(p.join(tempDir.path, 'OneDriveDesktop'));
        await fakeDesktop.create(recursive: true);

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(captureChannel, (MethodCall call) async {
              if (call.method == 'getKnownDesktopPath') {
                return fakeDesktop.path;
              }
              return null;
            });

        final saved = await StorageService.exportImageDialogWithFormat(
          bytes: [137, 80, 78, 71],
          fileName: 'desktop_snap',
          isJpg: false,
          customFolderPath: 'desktop',
        );

        expect(saved, isNotNull);
        expect(p.dirname(saved!), fakeDesktop.path);
        expect(File(saved).existsSync(), isTrue);
      },
    );
  });
}
