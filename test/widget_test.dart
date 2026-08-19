import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/models/app_shortcut.dart';
import 'package:snipsnap/models/tool_properties.dart';
import 'package:snipsnap/services/shortcut_service.dart';
import 'package:snipsnap/services/storage_service.dart';
import 'package:snipsnap/utils/constants.dart';
import 'package:snipsnap/views/components/tool_sidebar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
    return Directory.systemTemp.path;
  });

  test('CustomShortcut model and JSON serialization', () {
    final shortcut = CustomShortcut(
      action: AppShortcutAction.interactiveSnip,
      keyId: LogicalKeyboardKey.keyS.keyId,
      keyLabel: 'S',
      meta: true,
      shift: true,
    );

    expect(shortcut.action, AppShortcutAction.interactiveSnip);
    expect(shortcut.toDisplayString(), contains('S'));

    final json = shortcut.toJson();
    final restored = CustomShortcut.fromJson(json);
    expect(restored.action, AppShortcutAction.interactiveSnip);
    expect(restored.keyId, LogicalKeyboardKey.keyS.keyId);
    expect(restored.meta, isTrue);
    expect(restored.shift, isTrue);
  });

  test('ShortcutService default shortcuts', () {
    final defaults = ShortcutService.getDefaultShortcuts();
    expect(defaults.length, AppShortcutAction.values.length);
    expect(defaults.containsKey(AppShortcutAction.interactiveSnip), isTrue);
    expect(defaults.containsKey(AppShortcutAction.copyToClipboard), isTrue);
  });

  test('CustomShortcut copyWith preserves fields', () {
    final shortcut = CustomShortcut(
      action: AppShortcutAction.undo,
      keyId: LogicalKeyboardKey.keyZ.keyId,
      keyLabel: 'Z',
      meta: true,
    );
    final modified = shortcut.copyWith(shift: true);
    expect(modified.action, AppShortcutAction.undo);
    expect(modified.meta, isTrue);
    expect(modified.shift, isTrue);
    expect(modified.keyLabel, 'Z');
  });

  test('Default shortcuts include only system-level capture triggers', () {
    // interactiveSnip, fullScreenSnip, timerSnip should be in defaults
    final defaults = ShortcutService.getDefaultShortcuts();
    expect(defaults.containsKey(AppShortcutAction.interactiveSnip), isTrue);
    expect(defaults.containsKey(AppShortcutAction.fullScreenSnip), isTrue);
    expect(defaults.containsKey(AppShortcutAction.timerSnip), isTrue);
    // Other standard editing shortcuts should also be in defaults
    expect(defaults.containsKey(AppShortcutAction.undo), isTrue);
    expect(defaults.containsKey(AppShortcutAction.redo), isTrue);
    expect(defaults.containsKey(AppShortcutAction.saveAs), isTrue);
    expect(defaults.containsKey(AppShortcutAction.flattenCanvas), isTrue);
  });

  test('CanvasTool enum and stroke width presets verification', () {
    expect(CanvasTool.values.length, 14);
    expect(CanvasTool.values, contains(CanvasTool.pen));
    expect(CanvasTool.values, contains(CanvasTool.line));
    expect(CanvasTool.values, contains(CanvasTool.blur));
    expect(CanvasTool.values, contains(CanvasTool.ruler));
    expect(CanvasTool.values, contains(CanvasTool.crop));
    // Rectangle and oval were merged into the multi-shape tool.
    expect(CanvasTool.values, contains(CanvasTool.shape));
    expect(CanvasTool.values, contains(CanvasTool.ocr));
    expect(CanvasTool.values.map((t) => t.name), isNot(contains('rectangle')));
    expect(CanvasTool.values.map((t) => t.name), isNot(contains('oval')));

    expect(AppDefaults.strokeWidthThin, 2.0);
    expect(AppDefaults.strokeWidthMedium, 4.0);
    expect(AppDefaults.strokeWidthThick, 8.0);
    expect(AppDefaults.strokeWidthHeavy, 14.0);
  });

  test('every tool in the sidebar has default properties', () {
    final defaults = ToolProperties.createDefaults();
    for (final item in ToolSidebar.tools) {
      expect(defaults.containsKey(item.tool), isTrue,
          reason: '${item.tool} is offered in the sidebar but has no defaults');
    }
  });

  test('Flatten shortcut display properties', () {
    expect(AppShortcutAction.flattenCanvas.displayName, 'Flatten Annotations');
    expect(AppShortcutAction.flattenCanvas.description, contains('Bake all annotations'));
  });

  test('StorageService library directory contains SnipSnap/Captures path', () async {
    final dir = await StorageService.getLibraryDirectory();
    expect(dir.path, contains('SnipSnap'));
    expect(dir.path, contains('Captures'));
  });
}
