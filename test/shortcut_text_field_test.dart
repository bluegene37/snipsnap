import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The guard `MainScreen._isTextFieldFocused` applies, reproduced standalone.
bool _textFieldFocused() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  return ctx.widget is EditableText ||
      ctx.findAncestorWidgetOfExactType<EditableText>() != null;
}

Future<int> _pressCmdC(
  WidgetTester tester, {
  required bool guarded,
}) async {
  var fired = 0;
  final controller = TextEditingController(text: 'hello world');
  addTearDown(controller.dispose);

  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyC, meta: true): () {
            if (guarded && _textFieldFocused()) return;
            fired++;
          },
        },
        child: Focus(autofocus: true, child: TextField(controller: controller)),
      ),
    ),
  ));
  await tester.tap(find.byType(TextField));
  await tester.pumpAndSettle();
  controller.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
  await tester.pumpAndSettle();

  await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
  await tester.pumpAndSettle();
  return fired;
}

void main() {
  testWidgets('an app-level chord reaches a focused text field unless guarded',
      (tester) async {
    // The bug: `CallbackShortcuts` sits inside the MaterialApp, so it is BELOW
    // `DefaultTextEditingShortcuts` — and a key event travels up from the
    // focused node, hitting the app binding first. Cmd+C while typing an
    // on-canvas text annotation copied the whole screenshot instead of the
    // selected characters.
    expect(await _pressCmdC(tester, guarded: false), 1,
        reason: 'unguarded, the app binding pre-empts the text field — this is '
            'the behaviour the guard exists to prevent');
  });

  testWidgets('the focus guard stops it', (tester) async {
    expect(await _pressCmdC(tester, guarded: true), 0,
        reason: 'with a field focused, editing intent must win');
  });

  testWidgets('the guard does not disarm shortcuts outside a text field',
      (tester) async {
    var fired = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyC, meta: true): () {
              if (_textFieldFocused()) return;
              fired++;
            },
          },
          child: const Focus(autofocus: true, child: SizedBox.expand()),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await tester.pumpAndSettle();

    expect(fired, 1, reason: 'copy-to-clipboard must still work on the canvas');
  });

  test('MainScreen actually applies the guard to every binding', () {
    // Source-level, matching the convention the other canvas guards use: the
    // wiring lives inside a 2000-line build path that cannot be pumped without
    // a database and a platform channel.
    final source = File('lib/views/main_screen.dart').readAsStringSync();
    final start = source.indexOf('Map<ShortcutActivator, VoidCallback> _buildShortcutBindings()');
    expect(start, isNot(-1));
    final body = source.substring(start, source.indexOf('\n  }\n', start));
    expect(body, contains('_isTextFieldFocused'),
        reason: 'every registered chord must check for a focused text field');
    expect(source, contains('bool get _isTextFieldFocused'));
  });
}
