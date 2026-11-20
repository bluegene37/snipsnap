// Gene - Oct, 27, 2026: Integration tests for panoramic scrolling capture integration (Task 5).
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:snipsnap/services/scrolling/image_stitcher.dart';
import 'package:snipsnap/services/scrolling/scrolling_capture_controller.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/capture/capture_overlay.dart';
import 'package:snipsnap/views/components/header_bar.dart';
import 'package:snipsnap/views/editor_canvas.dart';

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
    // Gene - Oct, 27, 2026: Verifies Panoramic buttons and dropdown options are omitted from the left top bar as requested.
    // Old implementation:
    // testWidgets(
    //   'shows Scrolling Capture option in dropdown when onSnipScrolling is provided',
    //   (tester) async {
    //     bool scrollingCalled = false;
    //     await tester.pumpWidget(
    //       _headerBarHarness(
    //         width: 1200,
    //         onSnipScrolling: () => scrollingCalled = true,
    //       ),
    //     );
    //
    //     // Open capture dropdown menu
    //     await tester.tap(find.byTooltip('Capture Modes'));
    //     await tester.pumpAndSettle();
    //
    //     expect(find.text('Scrolling Capture'), findsOneWidget);
    //     expect(find.text('Panoramic'), findsOneWidget);
    //
    //     await tester.tap(find.text('Scrolling Capture'));
    //     await tester.pumpAndSettle();
    //
    //     expect(scrollingCalled, isTrue);
    //   },
    // );
    // Gene - Nov, 20, 2026: Re-enabled Scrolling Capture dropdown item while keeping top-left HeaderBar clean without standalone button.
    // Old implementation:
    // testWidgets(
    //   'omits Panoramic and Scrolling Capture buttons from HeaderBar and dropdown',
    //   (tester) async {
    //     await tester.pumpWidget(
    //       _headerBarHarness(width: 1200, onSnipScrolling: () {}),
    //     );
    //
    //     // Header bar itself should not show Panoramic button
    //     expect(find.text('Panoramic'), findsNothing);
    //     expect(find.byIcon(Icons.unfold_more_rounded), findsNothing);
    //
    //     // Open capture dropdown menu
    //     await tester.tap(find.byTooltip('Capture Modes'));
    //     await tester.pumpAndSettle();
    //
    //     expect(find.text('Scrolling Capture'), findsNothing);
    //   },
    // );
    testWidgets(
      'keeps HeaderBar uncluttered while exposing Scrolling Capture inside dropdown when enabled',
      (tester) async {
        var scrollingCalled = false;
        await tester.pumpWidget(
          _headerBarHarness(
            width: 1200,
            onSnipScrolling: () => scrollingCalled = true,
          ),
        );

        // Header bar itself should not show a standalone Panoramic button
        expect(find.text('Panoramic'), findsNothing);
        expect(find.byIcon(Icons.unfold_more_rounded), findsNothing);

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

  group('StitchStripSession O(N) Fallback Assembly', () {
    img.Image makePattern(int width, int height, {int offsetY = 0}) {
      final image = img.Image(width: width, height: height);
      for (var y = 0; y < height; y++) {
        final gy = y + offsetY;
        final c = img.ColorRgb8(
          (gy * 7) % 256,
          (gy * 13) % 256,
          (gy * 17) % 256,
        );
        for (var x = 0; x < width; x++) {
          image.setPixel(x, y, c);
        }
      }
      return image;
    }

    test(
      'accumulates scrolled tail slices and assembles single composite image',
      () {
        final session = StitchStripSession(
          stitcher: ImageStitcher(
            scrollbarIgnoreMargin: 5,
            maxMatchError: 30.0,
          ),
        );
        final r1 = session.pushFrame(makePattern(200, 100, offsetY: 0));
        expect(r1.isMatchValid, isTrue);
        expect(session.cumulativeHeight, 100);

        final r2 = session.pushFrame(makePattern(200, 100, offsetY: 30));
        expect(r2.shiftY, 30);
        expect(session.cumulativeHeight, 130);

        final r3 = session.pushFrame(makePattern(200, 100, offsetY: 60));
        expect(r3.shiftY, 30);
        expect(session.cumulativeHeight, 160);

        final assembled = session.assemble();
        expect(assembled, isNotNull);
        expect(assembled!.width, 200);
        expect(assembled.height, 160);
      },
    );
  });

  group('ScrollingCaptureController Native Rust Engine Channel', () {
    const channel = MethodChannel('snipsnap/capture');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test(
      'streams native Rust progress events and resolves completion path',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'snipsnap_native_scroll_test',
        );
        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final calls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls.add(call);
              return true;
            });

        final controller = ScrollingCaptureController(
          useNativeEngine: true,
          storageDirectoryProvider: () async => tempDir,
        );

        await controller.startCapture(
          viewportRect: const Rect.fromLTWH(50, 80, 500, 400),
          devicePixelRatio: 2.0,
          maxDimension: 16000,
        );

        expect(calls.map((c) => c.method), contains('startScrollingCapture'));
        expect(controller.status, ScrollingCaptureStatus.capturing);

        await controller.setAutoScroll(true);
        expect(calls.map((c) => c.method), contains('setScrollingAutoMode'));
        expect(controller.isAutoScrolling, isTrue);

        // Simulate native Rust progress callback
        const codec = StandardMethodCodec();
        final progressBytes = codec.encodeMethodCall(
          const MethodCall('onScrollingProgress', {
            'width': 1000,
            'height': 2400,
            'frameCount': 18,
            'axis': 1,
            'status': 0,
            'isPaused': false,
            'isAutoScrolling': true,
          }),
        );
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage('snipsnap/capture', progressBytes, (_) {});

        expect(controller.cumulativeWidth, 1000);
        expect(controller.cumulativeHeight, 2400);
        expect(controller.frameCount, 18);

        final outPath = '${tempDir.path}/result_scroll.png';
        final completedBytes = codec.encodeMethodCall(
          MethodCall('onScrollingCompleted', {
            'path': outPath,
            'width': 1000,
            'height': 2800,
            'frameCount': 22,
            'axis': 1,
            'truncated': false,
          }),
        );
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage('snipsnap/capture', completedBytes, (_) {});

        final resolved = await controller.waitForNativeCompletion();
        expect(resolved, outPath);
        expect(controller.status, ScrollingCaptureStatus.completed);
        expect(controller.cumulativeHeight, 2800);
        controller.dispose();
      },
      skip: !(Platform.isMacOS || Platform.isWindows),
    );
  });

  group('Panoramic Initial Viewport Auto-Zoom', () {
    test(
      'fits tall scrolling capture to width top-aligned without exceeding maxZoom',
      () {
        final matrix = computeInitialPanoramicTransform(
          viewportSize: const Size(1200, 800),
          imageSize: const Size(1000, 6000),
        );
        expect(matrix, isNotNull);
        final scale = matrix!.getMaxScaleOnAxis();
        expect(scale, greaterThan(1.5));
        expect(scale, lessThanOrEqualTo(4.0));
        expect(matrix.storage[13], 0.0); // Top-aligned
      },
    );

    test(
      'caps tall capture initial zoom at 1:1 native pixels to prevent blur',
      () {
        // 400x1200 in 1200x800 => fitScale = 800/1200 = 2/3, native 1:1 = 1.5x
        final matrix = computeInitialPanoramicTransform(
          viewportSize: const Size(1200, 800),
          imageSize: const Size(400, 1200),
        );
        expect(matrix, isNotNull);
        expect(matrix!.getMaxScaleOnAxis(), closeTo(1.5, 0.01));
        expect(matrix.storage[13], 0.0);
      },
    );

    test('fits wide panorama to height left-aligned', () {
      final matrix = computeInitialPanoramicTransform(
        viewportSize: const Size(1200, 800),
        imageSize: const Size(6000, 800),
      );
      expect(matrix, isNotNull);
      expect(matrix!.getMaxScaleOnAxis(), greaterThan(1.5));
      expect(matrix.storage[12], 0.0); // Left-aligned
    });

    test('leaves normal aspect ratio capture unzoomed (null)', () {
      final matrix = computeInitialPanoramicTransform(
        viewportSize: const Size(1200, 800),
        imageSize: const Size(1600, 900),
      );
      expect(matrix, isNull);
    });
  });
}
