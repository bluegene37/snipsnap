import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/models/app_shortcut.dart';
import 'package:snipsnap/services/shortcut_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dev.leanflutter.plugins/hotkey_manager');
  late List<String> calls;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('releasing the OS hotkeys reaches the platform', () async {
    // The shortcut editor holds these down for as long as it is open. They are
    // registered at system level and fire before Flutter sees the key, so
    // recording a chord that matched a live capture shortcut took a screenshot
    // instead of being written into the field.
    await ShortcutService.unregisterGlobalHotKeys();
    expect(calls, contains('unregisterAll'));
  });

  test('a refused chord does not cost the rest of the loop', () async {
    // Registration is scoped per hotkey. One chord the OS owns used to abort
    // the whole loop from inside a shared try, silently costing the user every
    // shortcut after it.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (call.method == 'register' && calls.length == 2) {
            throw PlatformException(code: 'in_use');
          }
          return null;
        });

    final failed = await ShortcutService.registerGlobalHotKeys(
      shortcuts: ShortcutService.getDefaultShortcuts(),
      onHotKeyTriggered: (_) {},
    );

    expect(
      calls.where((c) => c == 'register').length,
      3,
      reason: 'all three capture hotkeys must still be attempted',
    );
    expect(failed, isNotEmpty, reason: 'and the refusal is reported back');
  });

  test('the macOS system screenshot chords are refused up front', () {
    // Cmd+Shift+3/4/5 belong to the OS. Registering one succeeds and then
    // never fires, so the settings dialog rejects them rather than letting a
    // user configure a shortcut that silently does nothing.
    CustomShortcut chord(int keyId) => CustomShortcut(
      action: AppShortcutAction.timerSnip,
      keyId: keyId,
      keyLabel: '5',
      meta: true,
      shift: true,
    );

    // 0x35 is digit 5; 0x36 is digit 6, which the OS leaves alone.
    expect(ShortcutService.isReservedBySystem(chord(0x35)), isTrue);
    expect(ShortcutService.isReservedBySystem(chord(0x36)), isFalse);
    // macOS-only by design: no other platform reserves these, and
    // `isReservedBySystem` correctly says so.
  }, skip: Platform.isMacOS ? false : 'the reserved set is macOS-specific');
}
