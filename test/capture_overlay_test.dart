// The overlay widget: that a drag settles rather than capturing, that the
// Capture button is what commits, and that the keyboard agrees with both.
//
// The state machine underneath is covered in `capture_selection_test.dart`;
// this is about the wiring between it and the pointer, the button and the keys.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/views/capture/capture_overlay.dart';

class _Harness {
  final List<Rect> captured = [];
  int cancels = 0;
}

Future<_Harness> _pump(
  WidgetTester tester, {
  Size size = const Size(800, 600),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final h = _Harness();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: CaptureOverlay(
          onCapture: h.captured.add,
          onCancel: () => h.cancels++,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

Future<void> _drag(WidgetTester tester, Offset from, Offset to) async {
  final gesture = await tester.startGesture(
    from,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump(const Duration(milliseconds: 16));
  final steps = 10;
  for (var i = 1; i <= steps; i++) {
    await gesture.moveTo(Offset.lerp(from, to, i / steps)!);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a drag does not capture — it offers a Capture button', (
    tester,
  ) async {
    // The whole point of the change: releasing the mouse used to end the
    // capture, giving you whatever region you happened to let go on.
    final h = await _pump(tester);

    expect(find.text('Capture'), findsNothing, reason: 'nothing selected yet');

    await _drag(tester, const Offset(100, 100), const Offset(400, 300));

    expect(h.captured, isEmpty, reason: 'releasing must not capture');
    expect(find.text('Capture'), findsOneWidget);
  });

  testWidgets('the Capture button commits the region', (tester) async {
    final h = await _pump(tester);
    await _drag(tester, const Offset(100, 100), const Offset(400, 300));

    await tester.tap(find.text('Capture'));
    await tester.pumpAndSettle();

    expect(h.captured, hasLength(1));
    expect(h.captured.single, const Rect.fromLTRB(100, 100, 400, 300));
  });

  testWidgets('the region can be adjusted before it is captured', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _drag(tester, const Offset(100, 100), const Offset(400, 300));

    // Grab the bottom-right grip and pull it out.
    await _drag(tester, const Offset(400, 300), const Offset(500, 380));
    expect(h.captured, isEmpty, reason: 'adjusting is not capturing either');

    await tester.tap(find.text('Capture'));
    await tester.pumpAndSettle();

    expect(h.captured.single, const Rect.fromLTRB(100, 100, 500, 380));
  });

  testWidgets('a click with no drag captures the whole screen', (tester) async {
    final h = await _pump(tester);
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();

    expect(h.captured.single, const Rect.fromLTRB(0, 0, 800, 600));
  });

  testWidgets('a click outside a settled region starts a new one', (
    tester,
  ) async {
    // With the overlay now sitting open waiting, a stray click must not grab
    // the whole desktop.
    final h = await _pump(tester);
    await _drag(tester, const Offset(100, 100), const Offset(400, 300));
    await _drag(tester, const Offset(500, 400), const Offset(700, 550));

    expect(h.captured, isEmpty);
    await tester.tap(find.text('Capture'));
    await tester.pumpAndSettle();
    expect(h.captured.single, const Rect.fromLTRB(500, 400, 700, 550));
  });

  testWidgets('Return captures and Escape cancels', (tester) async {
    final h = await _pump(tester);
    await _drag(tester, const Offset(100, 100), const Offset(400, 300));

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(h.captured, hasLength(1));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(h.cancels, 1);
  });

  testWidgets('Return with nothing selected does nothing', (tester) async {
    final h = await _pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(h.captured, isEmpty);
    expect(h.cancels, 0);
  });
}
