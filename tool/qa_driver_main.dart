// QA harness entrypoint: the real app with the Flutter Driver extension
// enabled so /qa can tap widgets and take surface screenshots reliably.
// Run with:
//   flutter run -d macos -t tool/qa_driver_main.dart
// Never ship this target; it is driver-instrumented.
//
// Besides the stock driver commands, a custom handler accepts engine-level
// mouse gestures at arbitrary window coordinates (logical pixels), which the
// stock `tap`/`scroll` commands cannot do (they only start at widget centres):
//   'tap:x,y'                 primary-button click
//   'drag:x1,y1,x2,y2[,steps]' press, move in `steps` increments, release
//   'hover:x,y'               move the mouse without pressing
//   'key:<name>'              press+release backspace|delete|escape|enter
//   'wheel:x,y,dx,dy'         mouse-wheel scroll at (x,y) by (dx,dy)
// Everything is dispatched through the framework's own GestureBinding as
// PointerDeviceKind.mouse, so it never leaves the app or touches other apps.
import 'dart:async';
import 'dart:ui';

import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:flutter_test/flutter_test.dart' show LiveWidgetController;
import 'package:snipsnap/main.dart' as app;

// (logical key, physical key, macOS virtual key code) per supported name.
const _keys = <String, (LogicalKeyboardKey, PhysicalKeyboardKey, int)>{
  'backspace': (LogicalKeyboardKey.backspace, PhysicalKeyboardKey.backspace, 0x33),
  'delete': (LogicalKeyboardKey.delete, PhysicalKeyboardKey.delete, 0x75),
  'escape': (LogicalKeyboardKey.escape, PhysicalKeyboardKey.escape, 0x35),
  'enter': (LogicalKeyboardKey.enter, PhysicalKeyboardKey.enter, 0x24),
};

Future<void> _sendKey(String name, {required bool down}) async {
  final spec = _keys[name];
  if (spec == null) throw ArgumentError('unsupported key: $name');
  final (logical, physical, code) = spec;
  // The deprecated pair is the only way to feed a live app a key press that
  // the framework accepts as if it came from the embedder.
  // ignore: deprecated_member_use
  final manager = ServicesBinding.instance.keyEventManager;
  // ignore: deprecated_member_use
  manager.handleKeyData(
    KeyData(
      timeStamp: Duration(microseconds: DateTime.now().microsecondsSinceEpoch),
      type: down ? KeyEventType.down : KeyEventType.up,
      physical: physical.usbHidUsage,
      logical: logical.keyId,
      character: null,
      synthesized: false,
    ),
  );
  // ignore: deprecated_member_use
  await manager.handleRawKeyMessage(<String, dynamic>{
    'type': down ? 'keydown' : 'keyup',
    'keymap': 'macos',
    'keyCode': code,
    'characters': '',
    'charactersIgnoringModifiers': '',
    'modifiers': 0,
  });
}

Future<String> _handleQaCommand(String? message) async {
  final text = message ?? '';
  final sep = text.indexOf(':');
  final cmd = sep < 0 ? text : text.substring(0, sep);
  final nums = sep < 0 || cmd == 'key'
      ? const <double>[]
      : text.substring(sep + 1).split(',').map(double.parse).toList();
  final controller = LiveWidgetController(WidgetsBinding.instance);
  switch (cmd) {
    case 'key':
      final name = text.substring(sep + 1);
      await _sendKey(name, down: true);
      await _sendKey(name, down: false);
      return 'pressed $name';
    case 'tap':
      // Add/remove the pointer around every mouse gesture: MouseTracker asserts
      // that a device is not re-added while it still has a live pointer.
      final at = Offset(nums[0], nums[1]);
      final gesture = await controller.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await gesture.addPointer(location: at);
      await gesture.down(at);
      await gesture.up();
      await gesture.removePointer();
      return 'tapped $at';
    case 'wheel':
      final at = Offset(nums[0], nums[1]);
      final delta = Offset(nums[2], nums[3]);
      final gesture = await controller.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await gesture.addPointer(location: at);
      await controller.sendEventToBinding(
        PointerScrollEvent(position: at, scrollDelta: delta),
      );
      await gesture.removePointer();
      return 'wheeled $delta at $at';
    case 'hover':
      final gesture = await controller.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await gesture.addPointer(location: Offset(nums[0], nums[1]));
      await gesture.moveTo(Offset(nums[0], nums[1]));
      await gesture.removePointer();
      return 'hovered ${nums[0]},${nums[1]}';
    case 'drag':
      final from = Offset(nums[0], nums[1]);
      final to = Offset(nums[2], nums[3]);
      final steps = nums.length > 4 ? nums[4].toInt() : 24;
      final gesture = await controller.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await gesture.addPointer(location: from);
      await gesture.down(from);
      for (var i = 1; i <= steps; i++) {
        await gesture.moveTo(Offset.lerp(from, to, i / steps)!);
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await gesture.removePointer();
      return 'dragged $from -> $to in $steps steps';
    default:
      return 'unknown command: $text';
  }
}

void main() {
  enableFlutterDriverExtension(handler: _handleQaCommand);
  app.main();
}
