import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import '../models/app_shortcut.dart';
import 'database_service.dart';

class ShortcutService {
  static final Map<AppShortcutAction, CustomShortcut> _defaults = {
    AppShortcutAction.interactiveSnip: CustomShortcut(
      action: AppShortcutAction.interactiveSnip,
      keyId: LogicalKeyboardKey.digit1.keyId,
      keyLabel: '1',
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
    AppShortcutAction.openImage: CustomShortcut(
      action: AppShortcutAction.openImage,
      keyId: LogicalKeyboardKey.keyO.keyId,
      keyLabel: 'O',
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

  static Future<Map<AppShortcutAction, CustomShortcut>> loadShortcuts() async {
    try {
      final dbShortcuts = await DatabaseService.loadShortcutsFromDb();
      final map = Map<AppShortcutAction, CustomShortcut>.from(_defaults);
      if (dbShortcuts.isNotEmpty) {
        map.addAll(dbShortcuts);
      }
      return map;
    } catch (e) {
      debugPrint('SnipSnap shortcut error: $e');
    }
    return getDefaultShortcuts();
  }

  static Future<void> saveShortcuts(Map<AppShortcutAction, CustomShortcut> shortcuts) async {
    await DatabaseService.saveShortcutsToDb(shortcuts);
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

        // Only register global OS-wide hotkeys for specific actions
        if (action != AppShortcutAction.interactiveSnip &&
            action != AppShortcutAction.fullScreenSnip &&
            action != AppShortcutAction.timerSnip) {
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
