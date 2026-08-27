import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-level invariants. `MainScreen` cannot be pumped — it builds an
/// `EditorCanvas`, which emits `Image.file`, which hangs `flutter_tester`.
///
/// **These checks are grep, and grep cannot see structure.** This file was
/// green for the whole skeleton branch while every dialog in the app crashed
/// on open, because `contains('SnipThemeScope(')` says nothing about *where*
/// the scope sits relative to the navigator that hosts a dialog route. The
/// behavioural coverage lives in `test/dialog_route_theme_test.dart`; what
/// belongs here is only the handful of invariants that are genuinely
/// textual — chiefly `lib/main.dart`, which no widget test can pump because
/// its root is `MainScreen`.
String _src(String path) => File(path).readAsStringSync();

/// [_src] with comment lines stripped.
///
/// The invariants below are about what the code *constructs*, and both files
/// carry long doc comments explaining the very constructs they must not use —
/// `lib/main.dart`'s comment says the word "MaterialApp" nine times while
/// building none. Matching raw source would fail on the explanation rather
/// than on the code.
String _code(String path) => _src(
  path,
).split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n');

void main() {
  test('the app is wrapped in a SnipThemeScope', () {
    final source = _src('lib/views/main_screen.dart');
    expect(source, contains('SnipThemeScope('));
    expect(source, contains('SnipTheme.forMode('));
  });

  test('lib/main.dart builds no MaterialApp of its own', () {
    // A second MaterialApp above MainScreen puts the root navigator — the one
    // showDialog pushes onto by default — ABOVE SnipThemeScope, so every
    // dialog's `SnipTheme.of(context)` throws, and any stock Material chrome
    // inside a dialog resolves the outer app's baseline-purple M3 theme.
    // `MainScreen` builds the app's only MaterialApp, beneath the scope.
    //
    // This is the one arm of that bug no widget test can reach: main.dart's
    // root is MainScreen, which cannot be pumped. See
    // `test/dialog_route_theme_test.dart` for the behavioural half.
    final source = _code('lib/main.dart');
    expect(
      source,
      isNot(contains('MaterialApp(')),
      reason:
          'lib/main.dart must hand MainScreen straight to runApp — '
          'MainScreen builds the app\'s only MaterialApp, below SnipThemeScope',
    );
    expect(source, contains('runApp(const MainScreen())'));
  });

  test(
    'main_screen opens dialogs from a context inside its own MaterialApp',
    () {
      // The other half of the same fix. `_MainScreenState.context` sits above
      // the MaterialApp that its own build() mounts, so once main.dart stopped
      // supplying an outer app there was no Navigator and no
      // MaterialLocalizations above it at all — showDialog asserts
      // `No MaterialLocalizations found` before it even reaches the navigator.
      // Every showDialog call here must therefore go through the navigatorKey.
      final source = _code('lib/views/main_screen.dart');
      expect(source, contains('navigatorKey: _navigatorKey'));
      expect(
        source,
        isNot(contains('context: context,')),
        reason:
            'showDialog must take _dialogContext (the navigator\'s own '
            'context), never this State\'s context',
      );
      expect(
        RegExp(r'context: _dialogContext!,').allMatches(source).length,
        3,
        reason:
            'all three showDialog call sites (About, Keyboard Shortcuts, '
            'Save As) must route through the navigator context',
      );
    },
  );

  test('main_screen no longer hardcodes the violet accent', () {
    final source = _src('lib/views/main_screen.dart');
    expect(
      source,
      isNot(contains('AppColors.accent')),
      reason: 'chrome colour must come from SnipTheme, not AppColors',
    );
  });
}
