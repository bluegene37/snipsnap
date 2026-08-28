import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-level invariants for the updater wiring, in the style of
/// `test/snip_theme_wiring_test.dart`: `MainScreen` cannot be pumped (its
/// `EditorCanvas` emits `Image.file`, which hangs `flutter_tester`), so the
/// behavioural coverage lives in `test/update/update_gate_test.dart` and
/// these checks only pin that the wiring exists at all in `main_screen.dart`.
String _src(String path) => File(path).readAsStringSync();

void main() {
  final source = _src('lib/views/main_screen.dart');

  test('MainScreen mounts the UpdateGate on the stable root screen', () {
    expect(source, contains('UpdateGate('));
  });

  test('MainScreen owns and disposes an UpdateController', () {
    expect(source, contains('UpdateController('));
    expect(source, contains('_updateController.dispose()'));
  });

  test('the HeaderBar is handed the update controller', () {
    expect(source, contains('updateController: _updateController'));
  });
}
