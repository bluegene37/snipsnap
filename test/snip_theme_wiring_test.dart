import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-level invariants. `MainScreen` cannot be pumped — it builds an
/// `EditorCanvas`, which emits `Image.file`, which hangs `flutter_tester`.
String _src(String path) => File(path).readAsStringSync();

void main() {
  test('the app is wrapped in a SnipThemeScope', () {
    final source = _src('lib/views/main_screen.dart');
    expect(source, contains('SnipThemeScope('));
    expect(source, contains('SnipTheme.forMode('));
  });

  test('main_screen no longer hardcodes the violet accent', () {
    final source = _src('lib/views/main_screen.dart');
    expect(
      source,
      isNot(contains('AppColors.accent')),
      reason: 'chrome colour must come from SnipTheme, not AppColors',
    );
  });
}
