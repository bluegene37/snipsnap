import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/main.dart';
import 'package:snipsnap/models/app_shortcut.dart';
import 'package:snipsnap/services/shortcut_service.dart';

void main() {
  test('CustomShortcut model and JSON serialization', () {
    final shortcut = CustomShortcut(
      action: AppShortcutAction.interactiveSnip,
      keyId: LogicalKeyboardKey.keyS.keyId,
      keyLabel: 'S',
      meta: true,
      shift: true,
    );

    expect(shortcut.action, AppShortcutAction.interactiveSnip);
    expect(shortcut.toDisplayString(), contains('S'));

    final json = shortcut.toJson();
    final restored = CustomShortcut.fromJson(json);
    expect(restored.action, AppShortcutAction.interactiveSnip);
    expect(restored.keyId, LogicalKeyboardKey.keyS.keyId);
    expect(restored.meta, isTrue);
    expect(restored.shift, isTrue);
  });

  test('ShortcutService default shortcuts', () {
    final defaults = ShortcutService.getDefaultShortcuts();
    expect(defaults.length, AppShortcutAction.values.length);
    expect(defaults.containsKey(AppShortcutAction.interactiveSnip), isTrue);
    expect(defaults.containsKey(AppShortcutAction.copyToClipboard), isTrue);
  });

  testWidgets('SnipSnap app smoke test and shortcut button', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const SnipSnapApp());
    await tester.pumpAndSettle();

    // Verify app renders title
    expect(find.text('SnipSnap'), findsOneWidget);
  });
}
