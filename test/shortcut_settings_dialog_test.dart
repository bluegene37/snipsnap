import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/models/app_shortcut.dart';
import 'package:snipsnap/services/shortcut_service.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/dialogs/shortcut_settings_dialog.dart';

// ShortcutSettingsDialog embeds no Image.file — pumpable in both modes per
// the task-6 brief. Its shortcut list is a lazily-built ListView (not a
// Column), so an action further down needs scrolling into view before a
// finder can see it — dragUntilVisible below handles that.

Future<void> _pump(
  WidgetTester tester, {
  required SnipThemeMode mode,
  ValueChanged<Map<AppShortcutAction, CustomShortcut>>? onShortcutsSaved,
}) {
  return tester.pumpWidget(
    SnipThemeScope(
      theme: SnipTheme.forMode(mode),
      child: MaterialApp(
        home: Scaffold(
          body: ShortcutSettingsDialog(
            initialShortcuts: ShortcutService.getDefaultShortcuts(),
            onShortcutsSaved: onShortcutsSaved ?? (_) {},
          ),
        ),
      ),
    ),
  );
}

/// Taps the "Edit" button belonging to [displayName]'s own row, scrolling
/// that row into view first — with 11 rows in a 620px-tall dialog, several
/// actions are off-screen at rest.
Future<void> _startEditing(WidgetTester tester, String displayName) async {
  final rowText = find.text(displayName);
  await tester.dragUntilVisible(rowText, find.byType(Scrollable), const Offset(0, -60));
  await tester.pump();

  final row = find.ancestor(of: rowText, matching: find.byType(Container)).first;
  await tester.tap(find.descendant(of: row, matching: find.text('Edit')));
  await tester.pump();
}

void _runStateTests(SnipThemeMode mode) {
  final label = mode.name;
  final t = SnipTheme.forMode(mode);

  testWidgets('[$label] pumps cleanly and lists every shortcut action', (tester) async {
    await _pump(tester, mode: mode);

    for (final action in AppShortcutAction.values) {
      final finder = find.text(action.displayName);
      await tester.dragUntilVisible(finder, find.byType(Scrollable), const Offset(0, -60));
      expect(finder, findsOneWidget, reason: '$label: ${action.displayName}');
    }
  });

  testWidgets('[$label] header chrome routes through SnipTheme', (tester) async {
    await _pump(tester, mode: mode);

    final title = tester.widget<Text>(find.text('Keyboard Shortcuts'));
    expect(title.style?.color, t.ink, reason: '$label: dialog title colour');

    final dialog = tester.widget<Dialog>(find.byType(Dialog));
    expect(dialog.backgroundColor, t.surface, reason: '$label: dialog background');
  });

  testWidgets('[$label] tapping Edit puts a row into the active-plate "press hotkey" state',
      (tester) async {
    await _pump(tester, mode: mode);
    await _startEditing(tester, 'Interactive Area Snip');

    expect(find.text('Press hotkey...'), findsOneWidget);
    final pillText = tester.widget<Text>(find.text('Press hotkey...'));
    expect(pillText.style?.color, t.onActive, reason: '$label: pill text is the onActive knockout');

    final pillContainer = tester.widget<Container>(
      find.ancestor(of: find.text('Press hotkey...'), matching: find.byType(Container)).first,
    );
    expect((pillContainer.decoration as BoxDecoration).color, t.activeFill,
        reason: '$label: pill fill is the exclusive activeFill plate');

    final spinner = tester.widget<CircularProgressIndicator>(find.byType(CircularProgressIndicator));
    expect(spinner.color, t.onActive, reason: '$label: spinner colour');
  });

  testWidgets('[$label] a real shortcut collision shows the danger-toned error banner, '
      'never an inline red', (tester) async {
    // Only run this on macOS-shaped default shortcuts (meta-based) — the
    // suite runs on Darwin in this environment (Platform.isMacOS), matching
    // ShortcutService's own default set.
    if (!Platform.isMacOS) {
      return;
    }
    await _pump(tester, mode: mode);

    // Edit "Clear All Annotations" (default: meta+shift+K) and press
    // meta+shift+Z instead — that combo already belongs to "Redo Annotation"
    // (a different action), which must be flagged as a conflict.
    await _startEditing(tester, 'Clear All Annotations');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyZ);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();

    expect(find.textContaining('conflicts with'), findsOneWidget);

    final banner = tester.widget<Container>(
      find.ancestor(of: find.byIcon(Icons.warning_amber_rounded), matching: find.byType(Container)).first,
    );
    final decoration = banner.decoration as BoxDecoration;
    expect(decoration.color, t.danger.withValues(alpha: 0.2), reason: '$label: banner fill');
    expect(decoration.border!.top.color, t.danger.withValues(alpha: 0.4), reason: '$label: banner border');

    final icon = tester.widget<Icon>(find.byIcon(Icons.warning_amber_rounded));
    expect(icon.color, t.danger, reason: '$label: warning icon colour');
    expect(icon.color, isNot(Colors.redAccent));
  });

  testWidgets('[$label] Reset Defaults restores the stock shortcuts', (tester) async {
    await _pump(tester, mode: mode);

    await tester.tap(find.text('Reset Defaults'));
    await tester.pump();

    // No exception, dialog still shows every action.
    for (final action in AppShortcutAction.values) {
      final finder = find.text(action.displayName);
      await tester.dragUntilVisible(finder, find.byType(Scrollable), const Offset(0, -60));
      expect(finder, findsOneWidget, reason: '$label: ${action.displayName}');
    }
  });
}

void main() {
  for (final mode in SnipThemeMode.values) {
    _runStateTests(mode);
  }
}
