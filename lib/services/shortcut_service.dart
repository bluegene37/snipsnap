import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_shortcut.dart';
import 'database_service.dart';

class ShortcutService {
  // Gene - Nov, 03, 2026: Key used for secondary SharedPreferences backup of user shortcuts.
  static const String _backupShortcutsKey = 'custom_shortcuts_backup_json';

  static final Map<AppShortcutAction, CustomShortcut> _defaults = {
    // Gene - Nov, 03, 2026: Changed default hotkey for interactiveSnip (Area Snip) to Ctrl+Shift+X across all platforms so it overrides stock system chords.
    // Old implementation:
    // AppShortcutAction.interactiveSnip: CustomShortcut(
    //   action: AppShortcutAction.interactiveSnip,
    //   keyId: LogicalKeyboardKey.digit1.keyId,
    //   keyLabel: '1',
    //   meta: Platform.isMacOS,
    //   ctrl: !Platform.isMacOS,
    //   shift: true,
    // ),
    AppShortcutAction.interactiveSnip: CustomShortcut(
      action: AppShortcutAction.interactiveSnip,
      keyId: LogicalKeyboardKey.keyX.keyId,
      keyLabel: 'X',
      meta: false,
      ctrl: true,
      shift: true,
    ),
    // Gene - Oct, 27, 2026: Added default hotkey for scrollingSnip (Panoramic Snip).
    AppShortcutAction.scrollingSnip: CustomShortcut(
      action: AppShortcutAction.scrollingSnip,
      keyId: LogicalKeyboardKey.keyP.keyId,
      keyLabel: 'P',
      meta: Platform.isMacOS,
      ctrl: !Platform.isMacOS,
      shift: true,
    ),
    AppShortcutAction.fullScreenSnip: CustomShortcut(
      action: AppShortcutAction.fullScreenSnip,
      keyId: LogicalKeyboardKey.digit2.keyId,
      keyLabel: '2',
      meta: Platform.isMacOS,
      ctrl: !Platform.isMacOS,
      shift: true,
    ),
    // Digit 5 would be the obvious third slot, but Cmd+Shift+3/4/5 are the
    // macOS system screenshot chords — the OS wins, our registration is
    // shadowed, and pressing it appears to do nothing. Digit 6 is free.
    AppShortcutAction.timerSnip: CustomShortcut(
      action: AppShortcutAction.timerSnip,
      keyId: LogicalKeyboardKey.digit6.keyId,
      keyLabel: '6',
      meta: Platform.isMacOS,
      ctrl: !Platform.isMacOS,
      shift: true,
    ),
    // Gene - Nov, 08, 2026: Added default hotkeys for recordArea, recordFullScreen, and pasteImage.
    AppShortcutAction.recordArea: CustomShortcut(
      action: AppShortcutAction.recordArea,
      keyId: LogicalKeyboardKey.keyR.keyId,
      keyLabel: 'R',
      meta: Platform.isMacOS,
      ctrl: !Platform.isMacOS,
      shift: true,
    ),
    AppShortcutAction.recordFullScreen: CustomShortcut(
      action: AppShortcutAction.recordFullScreen,
      keyId: LogicalKeyboardKey.digit7.keyId,
      keyLabel: '7',
      meta: Platform.isMacOS,
      ctrl: !Platform.isMacOS,
      shift: true,
    ),
    AppShortcutAction.openImage: CustomShortcut(
      action: AppShortcutAction.openImage,
      keyId: LogicalKeyboardKey.keyO.keyId,
      keyLabel: 'O',
      meta: Platform.isMacOS,
      ctrl: !Platform.isMacOS,
    ),
    AppShortcutAction.pasteImage: CustomShortcut(
      action: AppShortcutAction.pasteImage,
      keyId: LogicalKeyboardKey.keyV.keyId,
      keyLabel: 'V',
      meta: Platform.isMacOS,
      ctrl: !Platform.isMacOS,
    ),
    AppShortcutAction.copyToClipboard: CustomShortcut(
      action: AppShortcutAction.copyToClipboard,
      keyId: LogicalKeyboardKey.keyC.keyId,
      keyLabel: 'C',
      meta: Platform.isMacOS,
      ctrl: !Platform.isMacOS,
    ),
    AppShortcutAction.saveAs: CustomShortcut(
      action: AppShortcutAction.saveAs,
      keyId: LogicalKeyboardKey.keyS.keyId,
      keyLabel: 'S',
      meta: Platform.isMacOS,
      ctrl: !Platform.isMacOS,
    ),
    AppShortcutAction.undo: CustomShortcut(
      action: AppShortcutAction.undo,
      keyId: LogicalKeyboardKey.keyZ.keyId,
      keyLabel: 'Z',
      meta: Platform.isMacOS,
      ctrl: !Platform.isMacOS,
    ),
    AppShortcutAction.redo: CustomShortcut(
      action: AppShortcutAction.redo,
      keyId: LogicalKeyboardKey.keyZ.keyId,
      keyLabel: 'Z',
      meta: Platform.isMacOS,
      ctrl: !Platform.isMacOS,
      shift: true,
    ),
    AppShortcutAction.clearAnnotations: CustomShortcut(
      action: AppShortcutAction.clearAnnotations,
      keyId: LogicalKeyboardKey.keyK.keyId,
      keyLabel: 'K',
      meta: Platform.isMacOS,
      ctrl: !Platform.isMacOS,
      shift: true,
    ),
    AppShortcutAction.toggleHistory: CustomShortcut(
      action: AppShortcutAction.toggleHistory,
      keyId: LogicalKeyboardKey.keyH.keyId,
      keyLabel: 'H',
      meta: Platform.isMacOS,
      ctrl: !Platform.isMacOS,
    ),
    AppShortcutAction.flattenCanvas: CustomShortcut(
      action: AppShortcutAction.flattenCanvas,
      keyId: LogicalKeyboardKey.keyF.keyId,
      keyLabel: 'F',
      meta: Platform.isMacOS,
      ctrl: !Platform.isMacOS,
      shift: true,
    ),
  };

  static Map<AppShortcutAction, CustomShortcut> getDefaultShortcuts() {
    return Map.from(_defaults);
  }

  // Gene - Nov, 03, 2026: Implemented dual-layer shortcut loading with SharedPreferences recovery.
  // Old implementation:
  // static Future<Map<AppShortcutAction, CustomShortcut>> loadShortcuts() async {
  //   try {
  //     final dbShortcuts = await DatabaseService.loadShortcutsFromDb();
  //     final map = Map<AppShortcutAction, CustomShortcut>.from(_defaults);
  //     if (dbShortcuts.isNotEmpty) {
  //       map.addAll(dbShortcuts);
  //     }
  //     return map;
  //   } catch (e) {
  //     debugPrint('SnipSnap shortcut error: $e');
  //   }
  //   return getDefaultShortcuts();
  // }
  //
  // static Future<void> saveShortcuts(
  //   Map<AppShortcutAction, CustomShortcut> shortcuts,
  // ) async {
  //   await DatabaseService.saveShortcutsToDb(shortcuts);
  // }
  static Future<Map<AppShortcutAction, CustomShortcut>> loadShortcuts() async {
    final map = Map<AppShortcutAction, CustomShortcut>.from(_defaults);

    // 1. Try loading from Drift SQLite DB
    Map<AppShortcutAction, CustomShortcut> dbShortcuts = {};
    try {
      dbShortcuts = await DatabaseService.loadShortcutsFromDb();
    } catch (e) {
      debugPrint('SnipSnap db shortcuts load error: $e');
    }

    if (dbShortcuts.isNotEmpty) {
      map.addAll(dbShortcuts);
      // Synchronize to SharedPreferences backup in the background
      unawaited(_backupToPrefs(dbShortcuts));
      return map;
    }

    // 2. If SQLite is empty or failed, attempt recovery from SharedPreferences backup
    try {
      final prefs = await SharedPreferences.getInstance();
      final backupRaw = prefs.getString(_backupShortcutsKey);
      if (backupRaw != null && backupRaw.isNotEmpty) {
        final List<dynamic> decoded = jsonDecode(backupRaw) as List<dynamic>;
        final restoredMap = <AppShortcutAction, CustomShortcut>{};
        for (final item in decoded) {
          if (item is Map<String, dynamic>) {
            final shortcut = CustomShortcut.fromJson(item);
            restoredMap[shortcut.action] = shortcut;
          }
        }
        if (restoredMap.isNotEmpty) {
          map.addAll(restoredMap);
          // Restore back into Drift SQLite DB so future DB queries succeed
          unawaited(DatabaseService.saveShortcutsToDb(map));
          return map;
        }
      }
    } catch (e) {
      debugPrint('SnipSnap prefs shortcuts fallback error: $e');
    }

    return map;
  }

  // Gene - Nov, 03, 2026: Implemented dual-layer persistence (Drift SQLite + SharedPreferences backup)
  // ensuring custom shortcuts survive database migrations and app updates.
  static Future<void> saveShortcuts(
    Map<AppShortcutAction, CustomShortcut> shortcuts,
  ) async {
    // 1. Save to primary Drift SQLite DB
    try {
      await DatabaseService.saveShortcutsToDb(shortcuts);
    } catch (e) {
      debugPrint('SnipSnap saveShortcutsToDb error: $e');
    }

    // 2. Save backup to SharedPreferences
    await _backupToPrefs(shortcuts);
  }

  static Future<void> _backupToPrefs(
    Map<AppShortcutAction, CustomShortcut> shortcuts,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final backupList = shortcuts.values.map((s) => s.toJson()).toList();
      await prefs.setString(_backupShortcutsKey, jsonEncode(backupList));
    } catch (e) {
      debugPrint('SnipSnap backup to prefs error: $e');
    }
  }

  /// Chords the OS claims for itself. Registering one of these succeeds
  /// silently and then never fires, so the settings UI rejects them up front
  /// rather than letting the user configure a dead shortcut.
  static bool isReservedBySystem(CustomShortcut shortcut) {
    if (!Platform.isMacOS) return false;
    // Compared by keyId rather than as a const Set of LogicalKeyboardKey,
    // which the analyzer rejects: the type overrides `==`.
    const systemScreenshotKeyIds = {0x33, 0x34, 0x35}; // digits 3, 4, 5
    return shortcut.meta &&
        shortcut.shift &&
        !shortcut.ctrl &&
        !shortcut.alt &&
        systemScreenshotKeyIds.contains(shortcut.keyId);
  }

  /// Registers the OS-wide capture hotkeys, returning the actions whose chord
  /// the system refused.
  ///
  /// Returning them rather than only logging is the point: a refused chord used
  /// to abort the rest of the loop from inside one shared `try`, so a single
  /// conflict silently cost the user every hotkey after it — and they were
  /// never told about any of it.
  static Future<Set<AppShortcutAction>> registerGlobalHotKeys({
    required Map<AppShortcutAction, CustomShortcut> shortcuts,
    required void Function(AppShortcutAction action) onHotKeyTriggered,
  }) async {
    final failed = <AppShortcutAction>{};
    try {
      await hotKeyManager.unregisterAll();

      for (final entry in shortcuts.entries) {
        final action = entry.key;

        // Gene - Oct, 30, 2026: Excluded scrollingSnip from global OS-wide capture hotkeys while panoramic capture is switched off for beta testing.
        // Old implementation:
        // // Gene - Oct, 27, 2026: Include scrollingSnip in registered global OS-wide capture hotkeys.
        // if (action != AppShortcutAction.interactiveSnip &&
        //     action != AppShortcutAction.scrollingSnip &&
        //     action != AppShortcutAction.fullScreenSnip &&
        //     action != AppShortcutAction.timerSnip) {
        //   continue;
        // }
        // Gene - Nov, 08, 2026: Include recordArea and recordFullScreen in global OS-wide capture hotkeys.
        // Old implementation:
        // if (action != AppShortcutAction.interactiveSnip &&
        //     action != AppShortcutAction.fullScreenSnip &&
        //     action != AppShortcutAction.timerSnip) {
        //   continue;
        // }
        // Only register global OS-wide hotkeys for active capture actions
        if (action != AppShortcutAction.interactiveSnip &&
            action != AppShortcutAction.fullScreenSnip &&
            action != AppShortcutAction.timerSnip &&
            action != AppShortcutAction.recordArea &&
            action != AppShortcutAction.recordFullScreen) {
          continue;
        }

        final custom = entry.value;

        final modifiers = <HotKeyModifier>[];
        if (custom.meta) modifiers.add(HotKeyModifier.meta);
        if (custom.ctrl) modifiers.add(HotKeyModifier.control);
        if (custom.shift) modifiers.add(HotKeyModifier.shift);
        if (custom.alt) modifiers.add(HotKeyModifier.alt);

        final hotKey = HotKey(
          key: custom.logicalKey,
          modifiers: modifiers,
          scope: HotKeyScope.system,
        );

        try {
          await hotKeyManager.register(
            hotKey,
            keyDownHandler: (hotKey) {
              onHotKeyTriggered(action);
            },
          );
          if (isReservedBySystem(custom)) failed.add(action);
        } catch (e) {
          // Scoped per hotkey so one refusal cannot abandon the others.
          debugPrint('SnipSnap could not register ${action.name}: $e');
          failed.add(action);
        }
      }
    } catch (e) {
      debugPrint('SnipSnap shortcut error: $e');
    }
    return failed;
  }

  /// Releases every global hotkey. Called on app exit so nothing outlives the
  /// process — today the OS reclaims them anyway, but that stops being true the
  /// moment this app grows a background or menu-bar mode.
  static Future<void> unregisterGlobalHotKeys() async {
    try {
      await hotKeyManager.unregisterAll();
    } catch (e) {
      debugPrint('SnipSnap shortcut teardown error: $e');
    }
  }
}
