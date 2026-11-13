import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:snipsnap/database/app_database.dart';
import 'package:snipsnap/services/database_service.dart';
import 'package:snipsnap/views/main_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const hotKeyChannel = MethodChannel('dev.leanflutter.plugins/hotkey_manager');
  const hotKeyEventChannel = MethodChannel(
    'dev.leanflutter.plugins/hotkey_manager_event',
  );
  const captureChannel = MethodChannel('snipsnap/capture');

  late Directory tempDir;
  final recordedHotKeyMethods = <String>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('snipsnap_startup_test_');
    recordedHotKeyMethods.clear();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (MethodCall call) async {
          return tempDir.path;
        });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(hotKeyChannel, (MethodCall call) async {
          recordedHotKeyMethods.add(call.method);
          return null;
        });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(hotKeyEventChannel, (MethodCall call) async {
          return null;
        });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(captureChannel, (MethodCall call) async {
          switch (call.method) {
            case 'accessibilityAuthorized':
              return false;
            case 'screenCaptureAuthorized':
              return false;
            case 'listAudioInputDevices':
              return <dynamic>[];
            default:
              return null;
          }
        });

    // Gene - Nov, 13, 2026: Use an in-memory database matching undo_clears_canvas_state_test.dart and avoid closing it in tearDown because MainScreen.dispose() writes window state asynchronously on unmount.
    DatabaseService.db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(hotKeyChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(hotKeyEventChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(captureChannel, null);
  });

  testWidgets(
    'startup does not show Open Settings toast when accessibilityAuthorized and screenCaptureAuthorized return false',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.runAsync(() async {
        await tester.pumpWidget(const MainScreen());
        await Future<void>.delayed(const Duration(milliseconds: 800));
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await tester.pump();
      });

      await tester.pumpAndSettle();
      // Gene - Nov, 13, 2026: Drain offline google_fonts / Ahem layout exceptions matching undo_clears_canvas_state_test.dart.
      while (tester.takeException() != null) {}

      expect(find.text('Open Settings'), findsNothing);
      expect(find.textContaining('Accessibility'), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(recordedHotKeyMethods, contains('register'));

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      while (tester.takeException() != null) {}
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    },
  );
}
