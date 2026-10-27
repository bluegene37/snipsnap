// Gene - Oct, 27, 2026: Widget tests for ScrollingCaptureHud.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/services/scrolling/scrolling_capture_controller.dart';
import 'package:snipsnap/views/capture/capture_overlay.dart';
import 'package:snipsnap/views/capture/scrolling_capture_hud.dart';

class _TestScrollingCaptureController extends ScrollingCaptureController {
  int _fakeHeight = 0;
  int _fakeFrames = 0;

  @override
  int get cumulativeHeight => _fakeHeight;

  @override
  int get frameCount => _fakeFrames;

  void update({required int height, required int frames}) {
    _fakeHeight = height;
    _fakeFrames = frames;
    notifyListeners();
  }
}

void main() {
  testWidgets(
    'ScrollingCaptureHud displays height counter and fires callbacks on tap',
    (tester) async {
      final controller = ScrollingCaptureController();
      bool doneCalled = false;
      bool cancelCalled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScrollingCaptureHud(
              controller: controller,
              onDone: () => doneCalled = true,
              onCancel: () => cancelCalled = true,
            ),
          ),
        ),
      );

      expect(find.textContaining('px'), findsOneWidget);
      expect(find.text('0 px'), findsOneWidget);
      expect(find.text('(0 frames)'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);

      await tester.tap(find.text('Done'));
      expect(doneCalled, isTrue);

      await tester.tap(find.byIcon(Icons.close_rounded));
      expect(cancelCalled, isTrue);
    },
  );

  testWidgets(
    'ScrollingCaptureHud triggers onDone on Enter and onCancel on Escape',
    (tester) async {
      final controller = ScrollingCaptureController();
      int doneCount = 0;
      int cancelCount = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScrollingCaptureHud(
              controller: controller,
              onDone: () => doneCount++,
              onCancel: () => cancelCount++,
            ),
          ),
        ),
      );

      // Send Enter key
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(doneCount, 1);

      // Send Numpad Enter key
      await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
      await tester.pump();
      expect(doneCount, 2);

      // Send Escape key
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(cancelCount, 1);
    },
  );

  testWidgets(
    'ScrollingCaptureHud updates displayed height and frames on controller notifications',
    (tester) async {
      final controller = _TestScrollingCaptureController();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScrollingCaptureHud(
              controller: controller,
              onDone: () {},
              onCancel: () {},
            ),
          ),
        ),
      );

      expect(find.text('0 px'), findsOneWidget);
      expect(find.text('(0 frames)'), findsOneWidget);

      controller.update(height: 1234, frames: 12);
      await tester.pump();

      expect(find.text('1234 px'), findsOneWidget);
      expect(find.text('(12 frames)'), findsOneWidget);
    },
  );

  testWidgets(
    'ScrollingCaptureHud settles with pumpAndSettle and verifies button colors',
    (tester) async {
      final controller = ScrollingCaptureController();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScrollingCaptureHud(
              controller: controller,
              onDone: () {},
              onCancel: () {},
            ),
          ),
        ),
      );

      // Ensure animation does not hang pumpAndSettle in test environment
      await tester.pumpAndSettle();

      final doneButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Done'),
      );
      expect(
        doneButton.style?.backgroundColor?.resolve({}),
        CaptureColors.coffee,
      );

      final cancelButton = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.close_rounded),
      );
      expect(
        cancelButton.style?.backgroundColor?.resolve({}),
        CaptureColors.bean,
      );
    },
  );
}
