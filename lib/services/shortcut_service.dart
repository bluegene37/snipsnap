import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_shortcut.dart';
// Gene - Nov, 24, 2026: Import CaptureService to register native Win32 RegisterHotKey shortcuts on Windows.
import 'capture_service.dart';
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
          // Gene - Nov, 09, 2026: Catch errors on background DB restore so an unavailable database never triggers an unhandled async exception.
          // Old implementation:
          // // Restore back into Drift SQLite DB so future DB queries succeed
          // unawaited(DatabaseService.saveShortcutsToDb(map));
          unawaited(
            DatabaseService.saveShortcutsToDb(map).catchError((Object e) {
              debugPrint('SnipSnap restoreShortcutsToDb error: $e');
            }),
          );
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

  // Gene - Nov, 24, 2026: Testable OS flags, Windows VK translation, expanded OS-reserved chord checks, and native Win32 MOD_NOREPEAT hotkey registration.
  @visibleForTesting
  static bool? debugIsWindowsOverride;

  @visibleForTesting
  static bool? debugIsMacOSOverride;

  static bool get _isWindows => debugIsWindowsOverride ?? Platform.isWindows;
  static bool get _isMacOS => debugIsMacOSOverride ?? Platform.isMacOS;

  static const Map<int, int> _specialKeyIdToVk = <int, int>{
    // Function keys F1-F24
    0x00100000801: 0x70, // f1
    0x00100000802: 0x71, // f2
    0x00100000803: 0x72, // f3
    0x00100000804: 0x73, // f4
    0x00100000805: 0x74, // f5
    0x00100000806: 0x75, // f6
    0x00100000807: 0x76, // f7
    0x00100000808: 0x77, // f8
    0x00100000809: 0x78, // f9
    0x0010000080A: 0x79, // f10
    0x0010000080B: 0x7A, // f11
    0x0010000080C: 0x7B, // f12
    0x0010000080D: 0x7C, // f13
    0x0010000080E: 0x7D, // f14
    0x0010000080F: 0x7E, // f15
    0x00100000810: 0x7F, // f16
    0x00100000811: 0x80, // f17
    0x00100000812: 0x81, // f18
    0x00100000813: 0x82, // f19
    0x00100000814: 0x83, // f20
    0x00100000815: 0x84, // f21
    0x00100000816: 0x85, // f22
    0x00100000817: 0x86, // f23
    0x00100000818: 0x87, // f24
    // Navigation, capture & editing keys
    0x00100000608: 0x2C, // printScreen
    0x00100000407: 0x2D, // insert
    0x0010000007F: 0x2E, // delete
    0x00100000306: 0x24, // home
    0x00100000305: 0x23, // end
    0x00100000308: 0x21, // pageUp
    0x00100000307: 0x22, // pageDown
    0x00100000302: 0x25, // arrowLeft
    0x00100000304: 0x26, // arrowUp
    0x00100000303: 0x27, // arrowRight
    0x00100000301: 0x28, // arrowDown
    0x00000000020: 0x20, // space
    0x00100000009: 0x09, // tab
    0x0010000000D: 0x0D, // enter
    0x0010000001B: 0x1B, // escape
    0x00100000008: 0x08, // backspace
    // Punctuation (US layout VK codes)
    0x0000000002D: 0xBD, // minus '-'
    0x0000000003D: 0xBB, // equal '='
    0x0000000005B: 0xDB, // bracketLeft '['
    0x0000000005D: 0xDD, // bracketRight ']'
    0x0000000005C: 0xDC, // backslash '\'
    0x0000000003B: 0xBA, // semicolon ';'
    0x00000000027: 0xDE, // quoteSingle '''
    0x0000000002C: 0xBC, // comma ','
    0x0000000002E: 0xBE, // period '.'
    0x0000000002F: 0xBF, // slash '/'
    0x00000000060: 0xC0, // backquote '`'
  };

  /// Translates a Flutter [LogicalKeyboardKey] into a Win32 Virtual-Key code
  /// for `RegisterHotKey`, or returns `null` when unmapped.
  static int? logicalKeyToWindowsVk(LogicalKeyboardKey key) {
    final id = key.keyId;
    if (id >= 0x61 && id <= 0x7A) {
      return id - 0x20; // 'a'..'z' -> 'A'..'Z' (0x41..0x5A)
    }
    if (id >= 0x30 && id <= 0x39) {
      return id; // '0'..'9' (0x30..0x39)
    }
    final special = _specialKeyIdToVk[id];
    if (special != null) return special;
    // Numpad 0..9 (0x200000230..0x200000239 -> VK_NUMPAD0..VK_NUMPAD9 0x60..0x69)
    if (id >= LogicalKeyboardKey.numpad0.keyId &&
        id <= LogicalKeyboardKey.numpad9.keyId) {
      return 0x60 + (id - LogicalKeyboardKey.numpad0.keyId);
    }
    return null;
  }

  /// Translates modifier flags into Win32 `MOD_ALT | MOD_CONTROL | MOD_SHIFT | MOD_WIN`.
  static int modifiersToWindowsMask(CustomShortcut shortcut) {
    var mask = 0;
    if (shortcut.alt) mask |= 0x0001; // MOD_ALT
    if (shortcut.ctrl) mask |= 0x0002; // MOD_CONTROL
    if (shortcut.shift) mask |= 0x0004; // MOD_SHIFT
    if (shortcut.meta) mask |= 0x0008; // MOD_WIN
    return mask;
  }

  /// Chords the OS claims for itself. Registering one of these succeeds
  /// silently and then never fires, so the settings UI rejects them up front
  /// rather than letting the user configure a dead shortcut.
  // Old implementation:
  // static bool isReservedBySystem(CustomShortcut shortcut) {
  //   if (!Platform.isMacOS) return false;
  //   const systemScreenshotKeyIds = {0x33, 0x34, 0x35}; // digits 3, 4, 5
  //   return shortcut.meta &&
  //       shortcut.shift &&
  //       !shortcut.ctrl &&
  //       !shortcut.alt &&
  //       systemScreenshotKeyIds.contains(shortcut.keyId);
  // }
  static bool isReservedBySystem(CustomShortcut shortcut) {
    if (_isMacOS) {
      // Compared by keyId rather than as a const Set of LogicalKeyboardKey,
      // which the analyzer rejects: the type overrides `==`.
      const systemScreenshotKeyIds = {0x33, 0x34, 0x35}; // digits 3, 4, 5
      return shortcut.meta &&
          shortcut.shift &&
          !shortcut.ctrl &&
          !shortcut.alt &&
          systemScreenshotKeyIds.contains(shortcut.keyId);
    }
    if (_isWindows) {
      final kid = shortcut.keyId;
      // Win+Shift+S (Snipping Tool)
      if (shortcut.meta &&
          shortcut.shift &&
          !shortcut.ctrl &&
          !shortcut.alt &&
          kid == LogicalKeyboardKey.keyS.keyId) {
        return true;
      }
      // Win+L, Win+D, Win+E, Win+R, Win+V, Win+G, Win+Tab
      if (shortcut.meta && !shortcut.shift && !shortcut.ctrl && !shortcut.alt) {
        if (kid == LogicalKeyboardKey.keyL.keyId ||
            kid == LogicalKeyboardKey.keyD.keyId ||
            kid == LogicalKeyboardKey.keyE.keyId ||
            kid == LogicalKeyboardKey.keyR.keyId ||
            kid == LogicalKeyboardKey.keyV.keyId ||
            kid == LogicalKeyboardKey.keyG.keyId ||
            kid == LogicalKeyboardKey.tab.keyId) {
          return true;
        }
      }
      // Alt+F4
      if (shortcut.alt &&
          !shortcut.ctrl &&
          !shortcut.shift &&
          !shortcut.meta &&
          kid == LogicalKeyboardKey.f4.keyId) {
        return true;
      }
      // Ctrl+Alt+Delete
      if (shortcut.ctrl &&
          shortcut.alt &&
          !shortcut.shift &&
          !shortcut.meta &&
          kid == LogicalKeyboardKey.delete.keyId) {
        return true;
      }
      // Ctrl+Shift+Escape (Task Manager)
      if (shortcut.ctrl &&
          shortcut.shift &&
          !shortcut.alt &&
          !shortcut.meta &&
          kid == LogicalKeyboardKey.escape.keyId) {
        return true;
      }
    }
    return false;
  }

  static bool _isCaptureHotKeyAction(AppShortcutAction action) {
    return action == AppShortcutAction.interactiveSnip ||
        action == AppShortcutAction.scrollingSnip ||
        action == AppShortcutAction.fullScreenSnip ||
        action == AppShortcutAction.timerSnip ||
        action == AppShortcutAction.recordArea ||
        action == AppShortcutAction.recordFullScreen;
  }

  /// Registers the OS-wide capture hotkeys, returning the actions whose chord
  /// the system refused.
  ///
  /// Returning them rather than only logging is the point: a refused chord used
  /// to abort the rest of the loop from inside one shared `try`, so a single
  /// conflict silently cost the user every hotkey after it — and they were
  /// never told about any of it.
  // Old implementation:
  // static Future<Set<AppShortcutAction>> registerGlobalHotKeys({ ... }) async {
  //   // Directly called hotKeyManager.unregisterAll() and hotKeyManager.register(...)
  //   // without MOD_NOREPEAT or RegisterHotKey return verification on Windows.
  // }
  static Future<Set<AppShortcutAction>> registerGlobalHotKeys({
    required Map<AppShortcutAction, CustomShortcut> shortcuts,
    required void Function(AppShortcutAction action) onHotKeyTriggered,
  }) async {
    final failed = <AppShortcutAction>{};

    if (_isWindows) {
      final captureService = CaptureService();
      captureService.setGlobalHotKeyCallback((actionName) {
        for (final action in AppShortcutAction.values) {
          if (action.name == actionName) {
            onHotKeyTriggered(action);
            break;
          }
        }
      });

      final entries = <Map<String, Object>>[];
      for (final entry in shortcuts.entries) {
        final action = entry.key;
        if (!_isCaptureHotKeyAction(action)) continue;
        final custom = entry.value;
        if (isReservedBySystem(custom)) {
          failed.add(action);
          continue;
        }
        final vk = logicalKeyToWindowsVk(custom.logicalKey);
        if (vk == null) {
          failed.add(action);
          continue;
        }
        entries.add({
          'action': action.name,
          'vk': vk,
          'modifiers': modifiersToWindowsMask(custom),
        });
      }

      try {
        final nativeFailed = await captureService.registerWindowsHotKeys(
          entries,
        );
        for (final name in nativeFailed) {
          for (final action in AppShortcutAction.values) {
            if (action.name == name) {
              failed.add(action);
              break;
            }
          }
        }
        return failed;
      } on MissingPluginException {
        // Fallback to hotkey_manager below when tested without native runner.
        failed.clear();
      } catch (e) {
        debugPrint('SnipSnap Windows native shortcut error: $e');
        failed.clear();
      }
    }

    try {
      await hotKeyManager.unregisterAll();

      for (final entry in shortcuts.entries) {
        final action = entry.key;
        if (!_isCaptureHotKeyAction(action)) {
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
  // Old implementation:
  // static Future<void> unregisterGlobalHotKeys() async {
  //   try {
  //     await hotKeyManager.unregisterAll();
  //   } catch (e) {
  //     debugPrint('SnipSnap shortcut teardown error: $e');
  //   }
  // }
  static Future<void> unregisterGlobalHotKeys() async {
    if (_isWindows) {
      CaptureService().setGlobalHotKeyCallback(null);
      try {
        await CaptureService().unregisterWindowsHotKeys();
        return;
      } on MissingPluginException {
        // Fall through to hotkey_manager in headless unit tests.
      } catch (e) {
        debugPrint('SnipSnap Windows shortcut teardown error: $e');
      }
    }
    try {
      await hotKeyManager.unregisterAll();
    } catch (e) {
      debugPrint('SnipSnap shortcut teardown error: $e');
    }
  }
}
