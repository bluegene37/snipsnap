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
      keyId: LogicalKeyboardKey.keyS.keyId,
      keyLabel: 'S',
      meta: Platform.isMacOS,
      ctrl: !Platform.isMacOS,
      shift: true,
    ),
    AppShortcutAction.fullScreenSnip: CustomShortcut(
      action: AppShortcutAction.fullScreenSnip,
      keyId: LogicalKeyboardKey.keyF.keyId,
      keyLabel: 'F',
      meta: Platform.isMacOS,
      ctrl: !Platform.isMacOS,
      shift: true,
    ),
    AppShortcutAction.timerSnip: CustomShortcut(
      action: AppShortcutAction.timerSnip,
      keyId: LogicalKeyboardKey.keyT.keyId,
      keyLabel: 'T',
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

  static Future<void> registerGlobalHotKeys({
    required Map<AppShortcutAction, CustomShortcut> shortcuts,
    required Function(AppShortcutAction action) onHotKeyTriggered,
  }) async {
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

        await hotKeyManager.register(
          hotKey,
          keyDownHandler: (hotKey) {
            onHotKeyTriggered(action);
          },
        );
      }
    } catch (e) {
      debugPrint('SnipSnap shortcut error: $e');
    }
  }
}
