// Gene - Oct, 27, 2026: Integration tests for panoramic scrolling capture integration (Task 5).
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/capture/capture_overlay.dart';
import 'package:snipsnap/views/components/header_bar.dart';

class _OverlayHarness {
  final List<Rect> captured = [];
  final List<Rect> scrollingCaptured = [];
  int cancels = 0;
}

Future<_OverlayHarness> _pumpOverlay(
  WidgetTester tester, {
  Size size = const Size(800, 600),
  bool enableScrollingCapture = false,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final h = _OverlayHarness();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: CaptureOverlay(
          onCapture: h.captured.add,
          onCancel: () => h.cancels++,
          onScrollingCapture: enableScrollingCapture
              ? h.scrollingCaptured.add
              : null,
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
  const steps = 10;
  for (var i = 1; i <= steps; i++) {
    await gesture.moveTo(Offset.lerp(from, to, i / steps)!);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

Widget _headerBarHarness({
  required double width,
  VoidCallback? onSnipScrolling,
  VoidCallback? onSnipInteractive,
}) {
  return SnipThemeScope(
    theme: SnipTheme.forMode(SnipThemeMode.dark),
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: width,
          child: HeaderBar(
            onSnipInteractive: onSnipInteractive ?? () {},
            onSnipScrolling: onSnipScrolling,
            onSnipFullScreen: () {},
            onSnipTimer: () {},
            onImportImage: () {},
            onUndo: () {},
            onRedo: () {},
            onClear: () {},
            onCopyToClipboard: () {},
            onSaveAs: () {},
            onToggleSidebar: () {},
            onToggleProperties: () {},
            onOpenShortcutSettings: () {},
            onToggleThemeMode: () {},
            onOpenAboutDialog: () {},
            canUndo: false,
            canRedo: false,
            canClear: false,
            hasCapture: false,
            isSidebarOpen: true,
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('CaptureOverlay Scrolling Button Integration', () {
    testWidgets('does not show Scroll button when onScrollingCapture is null', (
      tester,
    ) async {
      final h = await _pumpOverlay(tester, enableScrollingCapture: false);
      await _drag(tester, const Offset(100, 100), const Offset(400, 300));

      expect(find.text('Capture'), findsOneWidget);
      expect(find.text('Scroll'), findsNothing);
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);
      expect(h.captured, isEmpty);
    });

    testWidgets(
      'shows Scroll button when onScrollingCapture is provided and fires callback on tap',
      (tester) async {
        final h = await _pumpOverlay(tester, enableScrollingCapture: true);

        // Before drag, no controls are visible
        expect(find.text('Capture'), findsNothing);
        expect(find.text('Scroll'), findsNothing);
        expect(find.byIcon(Icons.unfold_more_rounded), findsNothing);

        await _drag(tester, const Offset(100, 100), const Offset(400, 300));

        // After settling, all controls exist
        expect(find.text('Capture'), findsOneWidget);
        expect(find.text('Scroll'), findsOneWidget);
        expect(find.byIcon(Icons.unfold_more_rounded), findsOneWidget);
        expect(find.byIcon(Icons.close_rounded), findsOneWidget);

        // Tap Scroll button
        await tester.tap(find.text('Scroll'));
        await tester.pumpAndSettle();

        expect(h.scrollingCaptured, hasLength(1));
        expect(
          h.scrollingCaptured.single,
          const Rect.fromLTRB(100, 100, 400, 300),
        );
        expect(h.captured, isEmpty);
      },
    );

    testWidgets(
      'tapping Capture commits region and leaves onScrollingCapture uncalled',
      (tester) async {
        final h = await _pumpOverlay(tester, enableScrollingCapture: true);
        await _drag(tester, const Offset(100, 100), const Offset(400, 300));

        await tester.tap(find.text('Capture'));
        await tester.pumpAndSettle();

        expect(h.captured, hasLength(1));
        expect(h.captured.single, const Rect.fromLTRB(100, 100, 400, 300));
        expect(h.scrollingCaptured, isEmpty);
      },
    );

    testWidgets(
      'all controls stay on screen when settled near bottom edge with onScrollingCapture',
      (tester) async {
        final h = await _pumpOverlay(tester, enableScrollingCapture: true);
        await _drag(tester, const Offset(80, 400), const Offset(760, 596));

        final size = tester.getSize(find.byType(CaptureOverlay));
        for (final finder in [
          find.text('Capture'),
          find.text('Scroll'),
          find.byIcon(Icons.close_rounded),
        ]) {
          final rect = tester.getRect(finder);
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.top, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(size.width));
          expect(rect.bottom, lessThanOrEqualTo(size.height));
        }
        expect(h.captured, isEmpty);
        expect(h.scrollingCaptured, isEmpty);
      },
    );
  });

  group('HeaderBar Scrolling Capture Integration', () {
    testWidgets(
      'shows Scrolling Capture option in dropdown when onSnipScrolling is provided',
      (tester) async {
        bool scrollingCalled = false;
        await tester.pumpWidget(
          _headerBarHarness(
            width: 1200,
            onSnipScrolling: () => scrollingCalled = true,
          ),
        );

        // Open capture dropdown menu
        await tester.tap(find.byTooltip('Capture Modes'));
        await tester.pumpAndSettle();

        expect(find.text('Scrolling Capture'), findsOneWidget);
        expect(find.text('Panoramic'), findsOneWidget);

        await tester.tap(find.text('Scrolling Capture'));
        await tester.pumpAndSettle();

        expect(scrollingCalled, isTrue);
      },
    );

    testWidgets(
      'omits Scrolling Capture in dropdown when onSnipScrolling is null',
      (tester) async {
        await tester.pumpWidget(
          _headerBarHarness(width: 1200, onSnipScrolling: null),
        );

        await tester.tap(find.byTooltip('Capture Modes'));
        await tester.pumpAndSettle();

        expect(find.text('Scrolling Capture'), findsNothing);
      },
    );
  });

  group('MainScreen Scrolling Capture Wiring & Flow', () {
    final mainScreenSource = File(
      'lib/views/main_screen.dart',
    ).readAsStringSync();

    test('MainScreen imports ScrollingCaptureController and HUD', () {
      expect(
        mainScreenSource,
        contains('scrolling/scrolling_capture_controller.dart'),
      );
      expect(mainScreenSource, contains('capture/scrolling_capture_hud.dart'));
    });

    test(
      'MainScreen implements _handleScrollingCapture with permissions and lifecycle',
      () {
        expect(
          mainScreenSource,
          contains('Future<void> _handleScrollingCapture'),
        );
        expect(mainScreenSource, contains('_ensureCapturePermission()'));
        expect(mainScreenSource, contains('ScrollingCaptureController('));
        expect(mainScreenSource, contains('_addCaptureFromPath('));
      },
    );

    test('HeaderBar is provided onSnipScrolling handler in MainScreen', () {
      expect(
        mainScreenSource,
        contains('onSnipScrolling: _handleScrollingCapture'),
      );
    });

    test(
      'MainScreen mounts ScrollingCaptureHud when scrolling session is active',
      () {
        expect(mainScreenSource, contains('ScrollingCaptureHud('));
      },
    );
  });
}
