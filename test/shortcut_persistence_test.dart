// Gene - Nov, 03, 2026: Unit tests for dual-layer shortcut persistence (SQLite + SharedPreferences)
// and default shortcut validation (Area Snip = Ctrl+Shift+X).

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:snipsnap/database/app_database.dart';
import 'package:snipsnap/models/app_shortcut.dart';
import 'package:snipsnap/services/database_service.dart';
import 'package:snipsnap/services/shortcut_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    DatabaseService.db = db;
  });

  tearDown(() async {
    await db.close();
  });

  test('default interactiveSnip is Ctrl+Shift+X across all platforms', () {
    final defaults = ShortcutService.getDefaultShortcuts();
    final areaSnip = defaults[AppShortcutAction.interactiveSnip]!;

    expect(areaSnip.action, AppShortcutAction.interactiveSnip);
    expect(areaSnip.keyLabel, 'X');
    expect(areaSnip.keyId, LogicalKeyboardKey.keyX.keyId);
    expect(areaSnip.ctrl, isTrue);
    expect(areaSnip.shift, isTrue);
    expect(areaSnip.meta, isFalse);
    expect(areaSnip.alt, isFalse);
  });

  test('saveShortcuts persists to both Drift SQLite and SharedPreferences', () async {
    final customShortcuts = ShortcutService.getDefaultShortcuts();
    customShortcuts[AppShortcutAction.interactiveSnip] = CustomShortcut(
      action: AppShortcutAction.interactiveSnip,
      keyId: LogicalKeyboardKey.keyA.keyId,
      keyLabel: 'A',
      ctrl: true,
      shift: true,
    );

    await ShortcutService.saveShortcuts(customShortcuts);

    // Verify saved to SQLite
    final fromDb = await DatabaseService.loadShortcutsFromDb();
    expect(fromDb[AppShortcutAction.interactiveSnip]?.keyLabel, 'A');

    // Verify saved to SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    final backup = prefs.getString('custom_shortcuts_backup_json');
    expect(backup, isNotNull);
    expect(backup, contains('"keyLabel":"A"'));
  });

  test('loadShortcuts falls back to SharedPreferences backup and restores DB when DB is empty', () async {
    // 1. Manually populate SharedPreferences with a custom shortcut
    final customShortcuts = ShortcutService.getDefaultShortcuts();
    customShortcuts[AppShortcutAction.fullScreenSnip] = CustomShortcut(
      action: AppShortcutAction.fullScreenSnip,
      keyId: LogicalKeyboardKey.keyF.keyId,
      keyLabel: 'F',
      ctrl: true,
      shift: true,
    );
    await ShortcutService.saveShortcuts(customShortcuts);

    // 2. Wipe SQLite table to simulate DB reset / fresh update migration
    await (db.delete(db.shortcuts)).go();
    final emptyDb = await DatabaseService.loadShortcutsFromDb();
    expect(emptyDb, isEmpty);

    // 3. Load shortcuts - should recover from SharedPreferences and restore SQLite
    final loaded = await ShortcutService.loadShortcuts();
    expect(loaded[AppShortcutAction.fullScreenSnip]?.keyLabel, 'F');

    // 4. Verify SQLite has been automatically restored
    final restoredDb = await DatabaseService.loadShortcutsFromDb();
    expect(restoredDb[AppShortcutAction.fullScreenSnip]?.keyLabel, 'F');
  });

  test('loadShortcuts syncs to SharedPreferences backup when loaded from DB', () async {
    // 1. Save directly to DB without SharedPreferences
    final customShortcuts = ShortcutService.getDefaultShortcuts();
    customShortcuts[AppShortcutAction.timerSnip] = CustomShortcut(
      action: AppShortcutAction.timerSnip,
      keyId: LogicalKeyboardKey.keyT.keyId,
      keyLabel: 'T',
      ctrl: true,
      shift: true,
    );
    await DatabaseService.saveShortcutsToDb(customShortcuts);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('custom_shortcuts_backup_json'), isNull);

    // 2. Load shortcuts - should load from DB and asynchronously sync to SharedPreferences
    final loaded = await ShortcutService.loadShortcuts();
    expect(loaded[AppShortcutAction.timerSnip]?.keyLabel, 'T');

    // Allow background unawaited future to complete
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final backup = prefs.getString('custom_shortcuts_backup_json');
    expect(backup, isNotNull);
    expect(backup, contains('"keyLabel":"T"'));
  });
}
