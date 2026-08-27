import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:snipsnap/utils/constants.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/editor_canvas.dart';

/// The live transform the canvas is rendering through.
Matrix4 _transform(WidgetTester tester) {
  final viewer = tester.widget<InteractiveViewer>(
    find.byType(InteractiveViewer),
  );
  return viewer.transformationController!.value;
}

double _scale(WidgetTester tester) => _transform(tester).getMaxScaleOnAxis();
Offset _translation(WidgetTester tester) {
  final s = _transform(tester).storage;
  return Offset(s[12], s[13]);
}

Future<void> _pumpCanvas(
  WidgetTester tester, {
  required String imagePath,
  required GlobalKey repaintKey,
  ValueChanged<double>? onZoom,
}) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(
      SnipThemeScope(
        theme: SnipTheme.forMode(SnipThemeMode.dark),
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 500,
              child: EditorCanvas(
                imagePath: imagePath,
                annotations: const [],
                activeTool: CanvasTool.select,
                activeColor: const Color(0xFF000000),
                strokeWidth: 4,
                fontSize: 16,
                isFilled: false,
                stepCounter: 1,
                onAnnotationAdded: (_) {},
                onStepCounterIncremented: (_) {},
                onZoomScaleChanged: onZoom,
                repaintBoundaryKey: repaintKey,
              ),
            ),
          ),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await tester.pump();
  });
  await tester.pumpAndSettle();
}

/// Sends a scroll signal at [at], optionally with a modifier held.
Future<void> _scroll(
  WidgetTester tester,
  Offset at,
  Offset delta, {
  LogicalKeyboardKey? holding,
}) async {
  if (holding != null) await tester.sendKeyDownEvent(holding);
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  pointer.hover(at);
  await tester.sendEventToBinding(pointer.scroll(delta));
  await tester.pumpAndSettle();
  if (holding != null) await tester.sendKeyUpEvent(holding);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late String imagePath;
  late GlobalKey repaintKey;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('snipsnap_zoom');
    imagePath = '${dir.path}/capture.png';
    final image = img.Image(width: 1600, height: 900);
    img.fill(image, color: img.ColorRgb8(180, 40, 40));
    File(imagePath).writeAsBytesSync(img.encodePng(image));
    repaintKey = GlobalKey();
  });

  tearDown(() => dir.deleteSync(recursive: true));

  testWidgets('scrolling pans once the view is zoomed in', (tester) async {
    // The behaviour every image editor has and this one did not: when the
    // capture is bigger than the window, the wheel moves you around it. Scroll
    // used to zoom unconditionally, so there was no pan gesture at all.
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpCanvas(tester, imagePath: imagePath, repaintKey: repaintKey);

    // Zoom in first — with the capture fitted there is nothing to pan to.
    await _scroll(
      tester,
      const Offset(300, 250),
      const Offset(0, -300),
      holding: LogicalKeyboardKey.metaLeft,
    );
    expect(_scale(tester), greaterThan(1.5), reason: 'Cmd+scroll must zoom');

    final before = _translation(tester);
    await _scroll(tester, const Offset(300, 250), const Offset(0, 120));
    final after = _translation(tester);

    expect(
      after.dy,
      lessThan(before.dy),
      reason: 'scrolling down moves the content up, i.e. reveals lower rows',
    );
    expect(_scale(tester), closeTo(_scale(tester), 0.001));
  });

  testWidgets('a plain scroll does not zoom any more', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpCanvas(tester, imagePath: imagePath, repaintKey: repaintKey);

    await _scroll(tester, const Offset(300, 250), const Offset(0, -240));
    expect(
      _scale(tester),
      closeTo(1.0, 0.001),
      reason: 'plain scroll is a pan gesture now, not a zoom',
    );
  });

  testWidgets('zoom holds the point under the cursor still', (tester) async {
    // The "it always centres" report: the old implementation rebuilt the matrix
    // from identity anchored on the viewport centre every step, so zooming in
    // on a corner walked the view back to the middle of the image.
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpCanvas(tester, imagePath: imagePath, repaintKey: repaintKey);

    const focal = Offset(120, 100);
    await _scroll(
      tester,
      focal,
      const Offset(0, -300),
      holding: LogicalKeyboardKey.metaLeft,
    );

    final m = _transform(tester);
    final scale = m.getMaxScaleOnAxis();
    expect(scale, greaterThan(1.2));

    // The content point that was under the cursor must still map to the cursor.
    final t = _translation(tester);
    final contentUnderCursor = Offset(
      (focal.dx - t.dx) / scale,
      (focal.dy - t.dy) / scale,
    );
    final reprojected = Offset(
      contentUnderCursor.dx * scale + t.dx,
      contentUnderCursor.dy * scale + t.dy,
    );
    expect(reprojected.dx, closeTo(focal.dx, 0.5));
    expect(reprojected.dy, closeTo(focal.dy, 0.5));
    // And it must not have snapped back to the middle of the viewport.
    expect(
      t.dx,
      isNot(closeTo((800 - 800 * scale) / 2, 1.0)),
      reason: 'a centre-anchored matrix would put tx exactly here',
    );
  });

  testWidgets('a pan survives the next zoom step', (tester) async {
    // Zoom used to be rebuilt from identity, so every step discarded the pan.
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpCanvas(tester, imagePath: imagePath, repaintKey: repaintKey);

    await _scroll(
      tester,
      const Offset(300, 250),
      const Offset(0, -300),
      holding: LogicalKeyboardKey.metaLeft,
    );
    await _scroll(tester, const Offset(300, 250), const Offset(0, 150));
    final panned = _translation(tester);
    expect(panned.dy, lessThan(0.0));

    await _scroll(
      tester,
      const Offset(300, 250),
      const Offset(0, -60),
      holding: LogicalKeyboardKey.metaLeft,
    );
    expect(
      _translation(tester).dy,
      lessThan(0.0),
      reason: 'zooming again must not throw the pan away',
    );
  });

  testWidgets('the content can never be panned out of sight', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpCanvas(tester, imagePath: imagePath, repaintKey: repaintKey);

    await _scroll(
      tester,
      const Offset(300, 250),
      const Offset(0, -300),
      holding: LogicalKeyboardKey.metaLeft,
    );
    for (var i = 0; i < 40; i++) {
      await _scroll(tester, const Offset(300, 250), const Offset(0, -400));
    }

    final t = _translation(tester);
    expect(
      t.dy,
      lessThanOrEqualTo(0.001),
      reason: 'the top edge is the furthest the content may travel down',
    );
    final scale = _scale(tester);
    final viewportH = tester.getSize(find.byType(InteractiveViewer)).height;
    expect(
      t.dy,
      greaterThanOrEqualTo(viewportH - viewportH * scale - 0.001),
      reason: 'and the bottom edge is the furthest the other way',
    );
  });

  testWidgets('drawing stays accurate while zoomed in and panned', (
    tester,
  ) async {
    // The coordinate contract this whole change had to preserve: gestures are
    // handled inside the transformed subtree, so Flutter applies the inverse
    // transform for hit testing and `localPosition` stays in child space no
    // matter how the view is zoomed or panned. If that ever stopped holding,
    // every stroke would land somewhere other than where it was drawn.
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    Rect? applied;
    final key = GlobalKey();
    await tester.runAsync(() async {
      await tester.pumpWidget(
        SnipThemeScope(
          theme: SnipTheme.forMode(SnipThemeMode.dark),
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 600,
                height: 500,
                child: EditorCanvas(
                  imagePath: imagePath,
                  annotations: const [],
                  activeTool: CanvasTool.crop,
                  activeColor: const Color(0xFF000000),
                  strokeWidth: 4,
                  fontSize: 16,
                  isFilled: false,
                  stepCounter: 1,
                  onAnnotationAdded: (_) {},
                  onStepCounterIncremented: (_) {},
                  onApplyCrop: (r) => applied = r,
                  repaintBoundaryKey: key,
                ),
              ),
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await tester.pump();
    });
    await tester.pumpAndSettle();

    await _scroll(
      tester,
      const Offset(200, 180),
      const Offset(0, -300),
      holding: LogicalKeyboardKey.metaLeft,
    );
    await _scroll(tester, const Offset(300, 250), const Offset(0, 90));
    final scale = _scale(tester);
    expect(scale, greaterThan(1.5), reason: 'the view must actually be zoomed');

    // Two points chosen in viewport space. Their child-space equivalents come
    // from the render box itself rather than from hand-rolled matrix maths, so
    // the expectation accounts for the transform *and* the vertical padding
    // between the viewer and the drawing surface.
    const fromView = Offset(180, 160);
    const toView = Offset(420, 330);
    final box = key.currentContext!.findRenderObject() as RenderBox;
    Offset toChild(Offset v) => box.globalToLocal(v);

    final gesture = await tester.startGesture(
      fromView,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveTo(fromView + const Offset(2, 2));
    await tester.pump(const Duration(milliseconds: 16));
    for (var i = 1; i <= 12; i++) {
      await gesture.moveTo(Offset.lerp(fromView, toView, i / 12)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('Apply'));
    await tester.pumpAndSettle();

    expect(applied, isNotNull);
    final expectedFrom = toChild(fromView);
    final expectedTo = toChild(toView);
    // Tolerance scales with the zoom: a 2px pointer nudge in viewport space is
    // 2/scale in child space.
    final tol = 4.0 / scale;
    expect(applied!.left, closeTo(expectedFrom.dx, tol));
    expect(applied!.top, closeTo(expectedFrom.dy, tol));
    expect(applied!.right, closeTo(expectedTo.dx, tol));
    expect(applied!.bottom, closeTo(expectedTo.dy, tol));
  });

  testWidgets('zoom stays within the range the header offers', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpCanvas(tester, imagePath: imagePath, repaintKey: repaintKey);

    for (var i = 0; i < 60; i++) {
      await _scroll(
        tester,
        const Offset(300, 250),
        const Offset(0, -400),
        holding: LogicalKeyboardKey.metaLeft,
      );
    }
    expect(_scale(tester), closeTo(4.0, 0.001));

    for (var i = 0; i < 120; i++) {
      await _scroll(
        tester,
        const Offset(300, 250),
        const Offset(0, 400),
        holding: LogicalKeyboardKey.metaLeft,
      );
    }
    expect(_scale(tester), closeTo(0.2, 0.001));
  });
}
