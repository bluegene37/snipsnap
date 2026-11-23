import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
// Gene - Nov, 23, 2026: Import services for Shift-key angle snapping tests on linear endpoint handles.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:snipsnap/models/annotation.dart';
import 'package:snipsnap/utils/constants.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/components/annotation_renderer.dart';
import 'package:snipsnap/views/editor_canvas.dart';

import 'support/base_image_settle.dart';

/// Everything the canvas emits is in image pixels, and so is everything it is
/// given, so ratios between a before and an after are projection-independent —
/// which is what these tests assert on.
class _Harness {
  _Harness(this.dir, this.imagePath, this.repaintKey);

  final Directory dir;
  final String imagePath;
  final GlobalKey repaintKey;

  List<Annotation> latest = const [];

  RenderBox get box =>
      repaintKey.currentContext!.findRenderObject() as RenderBox;
}

Future<_Harness> _pump(WidgetTester tester, Annotation seed) async {
  final dir = Directory.systemTemp.createTempSync('snipsnap_resize');
  final imagePath = '${dir.path}/capture.png';
  final image = img.Image(width: 1200, height: 900);
  img.fill(image, color: img.ColorRgb8(240, 240, 240));
  File(imagePath).writeAsBytesSync(img.encodePng(image));

  final harness = _Harness(dir, imagePath, GlobalKey());
  harness.latest = [seed];

  await tester.runAsync(() async {
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (ctx, setState) {
          return SnipThemeScope(
            theme: SnipTheme.forMode(SnipThemeMode.dark),
            child: MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 700,
                  height: 600,
                  child: EditorCanvas(
                    // Keyed per capture: tests that pump a second harness would
                    // otherwise update the existing canvas element, which keeps
                    // the outgoing bitmap on screen until the new decode lands
                    // — so settleBaseImage returns on the stale image (both are
                    // 1200x900) while the new file is still being read, and
                    // Windows then cannot delete it at teardown (errno 32).
                    key: ValueKey(imagePath),
                    imagePath: imagePath,
                    annotations: harness.latest,
                    activeTool: CanvasTool.select,
                    activeColor: const Color(0xFF000000),
                    strokeWidth: 6,
                    fontSize: 16,
                    isFilled: false,
                    stepCounter: 1,
                    onAnnotationAdded: (_) {},
                    onStepCounterIncremented: (_) {},
                    onAnnotationsUpdated: (list) =>
                        setState(() => harness.latest = list),
                    onAnnotationsLiveUpdated: (list) =>
                        setState(() => harness.latest = list),
                    repaintBoundaryKey: harness.repaintKey,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
    await settleBaseImage(tester);
  });
  await tester.pumpAndSettle();
  return harness;
}

Future<void> _dragFromTo(WidgetTester tester, Offset from, Offset to) async {
  final gesture = await tester.startGesture(
    from,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump(const Duration(milliseconds: 16));
  // Nudge past the pan slop along the drag's own direction. A diagonal nudge
  // would inject movement across the stroke and pollute the axis under test.
  final distance = (to - from).distance;
  final direction = (to - from) / distance;
  await gesture.moveTo(from + direction * 2);
  await tester.pump(const Duration(milliseconds: 16));
  // ~6px per step regardless of how far the drag goes. The pan is recognised on
  // the first step big enough to clear the slop, and that position becomes the
  // gesture's origin — so a coarse first step lands past the handle's hit
  // radius and the grab is missed entirely.
  final steps = math.max(12, (distance / 3).round());
  for (var i = 1; i <= steps; i++) {
    await gesture.moveTo(Offset.lerp(from, to, i / steps)!);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

/// Selects [harness]'s only annotation by clicking its middle, then returns the
/// canvas-space handle rect the resize handles are drawn on.
Future<Rect> _selectAndGetHandles(WidgetTester tester, _Harness harness) async {
  final ann = harness.latest.single;
  // Canvas space for the seeded annotation, via the same projection the canvas
  // uses: the image is letterboxed into the repaint boundary.
  final box = harness.box;
  final canvasAnn = _toCanvas(ann, box.size);
  final body = AnnotationRenderer.boundingRect(canvasAnn).center;

  await tester.tapAt(box.localToGlobal(body), kind: PointerDeviceKind.mouse);
  await tester.pumpAndSettle();
  return AnnotationRenderer.selectionRect(
    _toCanvas(harness.latest.single, box.size),
  );
}

Annotation _toCanvas(Annotation ann, Size canvasSize) {
  const imageSize = Size(1200, 900);
  final scale = math.min(
    canvasSize.width / imageSize.width,
    canvasSize.height / imageSize.height,
  );
  final dx = (canvasSize.width - imageSize.width * scale) / 2;
  final dy = (canvasSize.height - imageSize.height * scale) / 2;
  Offset map(Offset p) => Offset(p.dx * scale + dx, p.dy * scale + dy);
  return ann.copyWith(
    startPoint: ann.startPoint == null ? null : map(ann.startPoint!),
    endPoint: ann.endPoint == null ? null : map(ann.endPoint!),
    // Gene - Nov, 23, 2026: Project controlPoint into canvas space alongside endpoints when computing handle positions.
    controlPoint: ann.controlPoint == null ? null : map(ann.controlPoint!),
    points: ann.points.isEmpty ? null : ann.points.map(map).toList(),
    strokeWidth: ann.strokeWidth * scale,
  );
}

// Gene - Nov, 23, 2026: Commented out unused _length helper after migrating line/arrow/ruler tests to direct endpoint assertions.
// Old: double _length(Annotation a) => (a.endPoint! - a.startPoint!).distance;
double _angle(Annotation a) {
  final d = a.endPoint! - a.startPoint!;
  return math.atan2(d.dy, d.dx);
}

Annotation _pen({double strokeWidth = 5}) => Annotation(
  id: 'a1',
  tool: CanvasTool.pen,
  color: const Color(0xFF000000),
  strokeWidth: strokeWidth,
  startPoint: const Offset(300, 300),
  points: const [
    Offset(300, 300),
    Offset(420, 380),
    Offset(560, 340),
    Offset(700, 460),
  ],
);

/// A horizontal stroke, so screen axes and stroke axes coincide — the shape
/// the behaviour was reported against.
Annotation _flat(CanvasTool tool, {double strokeWidth = 8}) => Annotation(
  id: 'a1',
  tool: tool,
  color: const Color(0xFF000000),
  strokeWidth: strokeWidth,
  startPoint: const Offset(250, 450),
  endPoint: const Offset(900, 452),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => TestWidgetsFlutterBinding.ensureInitialized());

  // Gene - Nov, 23, 2026: Linear tools (line, arrow, ruler) now use direct endpoint and on-curve apex handles instead of 4-corner box scaling.
  // Old box-resize tests for line, arrow, and ruler:
  // for (final tool in const [CanvasTool.line, CanvasTool.ruler]) {
  //   testWidgets('dragging along a ${tool.name} changes its length only', ...);
  //   testWidgets('dragging across a ${tool.name} changes its thickness only', ...);
  // }
  // testWidgets('an arrow scales as one object from a corner drag', ...);
  // testWidgets('an arrow dragged across thickens at the pointer, head included', ...);
  // testWidgets('a big enough arrow drag still clears the old slider ceiling', ...);
  // testWidgets('the top-left handle thickens when pulled the other way', ...);
  // testWidgets('a vertical stroke lengthens when dragged vertically', ...);

  for (final tool in const [
    CanvasTool.line,
    CanvasTool.arrow,
    CanvasTool.ruler,
  ]) {
    testWidgets(
      'dragging ${tool.name} endPoint and startPoint moves only that endpoint without changing strokeWidth',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(900, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final h = await _pump(tester, _flat(tool, strokeWidth: 8));
        addTearDown(() => h.dir.deleteSync(recursive: true));

        final before = h.latest.single;
        final beforeCanvas = _toCanvas(before, h.box.size);
        await _selectAndGetHandles(tester, h);

        final endGlobal = h.box.localToGlobal(beforeCanvas.endPoint!);
        await _dragFromTo(
          tester,
          endGlobal,
          endGlobal + const Offset(-100, 120),
        );

        final afterEnd = h.latest.single;
        expect(
          afterEnd.startPoint!.dx,
          closeTo(before.startPoint!.dx, 2.0),
          reason: 'startPoint must stay anchored when dragging endPoint',
        );
        expect(afterEnd.startPoint!.dy, closeTo(before.startPoint!.dy, 2.0));
        expect(afterEnd.endPoint!.dx, lessThan(before.endPoint!.dx - 80));
        expect(afterEnd.endPoint!.dy, greaterThan(before.endPoint!.dy + 100));
        expect(
          afterEnd.strokeWidth,
          closeTo(before.strokeWidth, 0.01),
          reason: 'endpoint dragging must leave strokeWidth unchanged',
        );

        final midCanvas = _toCanvas(afterEnd, h.box.size);
        final startGlobal = h.box.localToGlobal(midCanvas.startPoint!);
        await _dragFromTo(
          tester,
          startGlobal,
          startGlobal + const Offset(60, -80),
        );

        final afterStart = h.latest.single;
        expect(
          afterStart.endPoint!.dx,
          closeTo(afterEnd.endPoint!.dx, 2.0),
          reason: 'endPoint must stay anchored when dragging startPoint',
        );
        expect(afterStart.endPoint!.dy, closeTo(afterEnd.endPoint!.dy, 2.0));
        expect(
          afterStart.startPoint!.dx,
          greaterThan(afterEnd.startPoint!.dx + 40),
        );
        expect(
          afterStart.startPoint!.dy,
          lessThan(afterEnd.startPoint!.dy - 60),
        );
        expect(afterStart.strokeWidth, closeTo(before.strokeWidth, 0.01));
      },
    );
  }

  testWidgets('Shift-dragging arrow endPoint snaps angle to 15° increments', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final h = await _pump(tester, _flat(CanvasTool.arrow, strokeWidth: 8));
    addTearDown(() => h.dir.deleteSync(recursive: true));

    final beforeCanvas = _toCanvas(h.latest.single, h.box.size);
    await _selectAndGetHandles(tester, h);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    final endGlobal = h.box.localToGlobal(beforeCanvas.endPoint!);
    await _dragFromTo(tester, endGlobal, endGlobal + const Offset(0, 120));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

    final angleDeg = _angle(h.latest.single) * 180 / math.pi;
    final nearest15 = (angleDeg / 15.0).round() * 15.0;
    expect(
      angleDeg,
      closeTo(nearest15, 0.5),
      reason: 'Shift must snap arrow angles to 15° steps',
    );
  });

  testWidgets('Shift-dragging ruler endPoint snaps angle to 45° increments', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final h = await _pump(tester, _flat(CanvasTool.ruler, strokeWidth: 6));
    addTearDown(() => h.dir.deleteSync(recursive: true));

    final beforeCanvas = _toCanvas(h.latest.single, h.box.size);
    await _selectAndGetHandles(tester, h);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    final endGlobal = h.box.localToGlobal(beforeCanvas.endPoint!);
    await _dragFromTo(tester, endGlobal, endGlobal + const Offset(-100, 180));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

    final angleDeg = _angle(h.latest.single) * 180 / math.pi;
    final nearest45 = (angleDeg / 45.0).round() * 45.0;
    expect(
      angleDeg,
      closeTo(nearest45, 0.5),
      reason: 'Shift must snap ruler angles to 45° steps',
    );
  });

  testWidgets(
    'dragging arrow curve apex handle curves directly under pointer, snaps straight near midpoint, and double-click straightens',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final h = await _pump(tester, _flat(CanvasTool.arrow, strokeWidth: 8));
      addTearDown(() => h.dir.deleteSync(recursive: true));

      final beforeCanvas = _toCanvas(h.latest.single, h.box.size);
      await _selectAndGetHandles(tester, h);

      final initialApexGlobal = h.box.localToGlobal(
        AnnotationRenderer.arrowCurveApex(beforeCanvas),
      );
      final targetApexGlobal = initialApexGlobal + const Offset(0, -80);
      await _dragFromTo(tester, initialApexGlobal, targetApexGlobal);

      final curvedCanvas = _toCanvas(h.latest.single, h.box.size);
      final actualApexGlobal = h.box.localToGlobal(
        AnnotationRenderer.arrowCurveApex(curvedCanvas),
      );
      expect(h.latest.single.controlPoint, isNotNull);
      expect(actualApexGlobal.dx, closeTo(targetApexGlobal.dx, 4.0));
      expect(actualApexGlobal.dy, closeTo(targetApexGlobal.dy, 4.0));

      // Double-click the on-curve apex handle to straighten back to controlPoint == null.
      await tester.tapAt(actualApexGlobal, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(actualApexGlobal, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(
        h.latest.single.controlPoint,
        isNull,
        reason: 'double-clicking the curve handle must straighten the arrow',
      );

      // Curve again, then drag back to midpoint to test snap-to-straight.
      await _dragFromTo(tester, initialApexGlobal, targetApexGlobal);
      expect(h.latest.single.controlPoint, isNotNull);
      final curvedApex2 = h.box.localToGlobal(
        AnnotationRenderer.arrowCurveApex(
          _toCanvas(h.latest.single, h.box.size),
        ),
      );
      await _dragFromTo(tester, curvedApex2, initialApexGlobal);
      expect(
        h.latest.single.controlPoint,
        isNull,
        reason: 'dragging apex back near chord midpoint must snap straight',
      );
    },
  );

  testWidgets('a pen stroke lengthens along its longer axis', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final h = await _pump(tester, _pen());
    addTearDown(() => h.dir.deleteSync(recursive: true));

    final before = h.latest.single;
    final beforeSpan = (before.points.last - before.points.first).distance;
    final handles = await _selectAndGetHandles(tester, h);

    // The pen's box is wider than it is tall, so its stand-in axis is
    // horizontal: drag purely along that.
    final corner = h.box.localToGlobal(handles.bottomRight);
    await _dragFromTo(tester, corner, corner + const Offset(140, 0));

    final after = h.latest.single;
    expect(after.points, hasLength(before.points.length));
    final afterSpan = (after.points.last - after.points.first).distance;
    final spanRatio = afterSpan / beforeSpan;

    expect(spanRatio, greaterThan(1.15));
    expect(
      after.strokeWidth,
      closeTo(before.strokeWidth, 0.01),
      reason:
          'a squiggle has no direction of its own, so its longer bounding '
          'axis stands in for one — dragging along it resizes, not thickens',
    );
  });

  testWidgets('a pen stroke never changes weight, whichever way it is dragged', (
    tester,
  ) async {
    // The pen keeps its thickness slider, so that stays the only way to change
    // a stroke's weight. Dragging a squiggle bigger makes it bigger, not
    // heavier — including straight across its axis, which for every other
    // stroke tool is the thicken gesture.
    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    for (final drag in const [Offset(0, 70), Offset(140, 0), Offset(100, 80)]) {
      final h = await _pump(tester, _pen());
      addTearDown(() => h.dir.deleteSync(recursive: true));

      final before = h.latest.single;
      final handles = await _selectAndGetHandles(tester, h);
      final corner = h.box.localToGlobal(handles.bottomRight);
      await _dragFromTo(tester, corner, corner + drag);

      expect(
        h.latest.single.strokeWidth,
        closeTo(before.strokeWidth, 0.01),
        reason: 'dragging $drag must leave the pen weight untouched',
      );
    }
  });

  testWidgets('a pen stroke scales in proportion from any corner drag', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final h = await _pump(tester, _pen());
    addTearDown(() => h.dir.deleteSync(recursive: true));

    final before = h.latest.single;
    final beforeW =
        (before.points.map((p) => p.dx).reduce(math.max)) -
        (before.points.map((p) => p.dx).reduce(math.min));
    final beforeH =
        (before.points.map((p) => p.dy).reduce(math.max)) -
        (before.points.map((p) => p.dy).reduce(math.min));

    final handles = await _selectAndGetHandles(tester, h);
    final corner = h.box.localToGlobal(handles.bottomRight);
    await _dragFromTo(tester, corner, corner + const Offset(0, 90));

    final after = h.latest.single;
    final afterW =
        (after.points.map((p) => p.dx).reduce(math.max)) -
        (after.points.map((p) => p.dx).reduce(math.min));
    final afterH =
        (after.points.map((p) => p.dy).reduce(math.max)) -
        (after.points.map((p) => p.dy).reduce(math.min));

    expect(
      afterH / beforeH,
      greaterThan(1.1),
      reason: 'a downward drag must grow it',
    );
    expect(
      afterW / beforeW,
      closeTo(afterH / beforeH, 0.02),
      reason:
          'and grow it by the same factor on both axes — proportionally, '
          'not stretched',
    );
  });

  testWidgets('the highlighter resizes on both axes like the other strokes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    Annotation marker() => Annotation(
      id: 'a1',
      tool: CanvasTool.highlight,
      color: const Color(0xFFFDE047),
      strokeWidth: 18,
      startPoint: const Offset(300, 400),
      points: const [
        Offset(300, 400),
        Offset(450, 405),
        Offset(620, 400),
        Offset(780, 408),
      ],
    );

    final along = await _pump(tester, marker());
    addTearDown(() => along.dir.deleteSync(recursive: true));
    final beforeAlong = along.latest.single;
    final beforeSpan =
        (beforeAlong.points.last - beforeAlong.points.first).distance;
    var handles = await _selectAndGetHandles(tester, along);
    await _dragFromTo(
      tester,
      along.box.localToGlobal(handles.bottomRight),
      along.box.localToGlobal(handles.bottomRight) + const Offset(150, 0),
    );
    final afterAlong = along.latest.single;
    expect(
      (afterAlong.points.last - afterAlong.points.first).distance / beforeSpan,
      greaterThan(1.15),
      reason: 'dragging along the band lengthens it',
    );
    expect(
      afterAlong.strokeWidth,
      closeTo(beforeAlong.strokeWidth, 0.5),
      reason: 'and leaves the band height alone',
    );

    final across = await _pump(tester, marker());
    addTearDown(() => across.dir.deleteSync(recursive: true));
    final beforeAcross = across.latest.single;
    handles = await _selectAndGetHandles(tester, across);
    await _dragFromTo(
      tester,
      across.box.localToGlobal(handles.bottomRight),
      across.box.localToGlobal(handles.bottomRight) + const Offset(0, 70),
    );
    expect(
      across.latest.single.strokeWidth / beforeAcross.strokeWidth,
      greaterThan(1.5),
      reason: 'dragging across it makes the band taller',
    );
  });

  // Gene - Nov, 23, 2026: Commented out line/ruler drag-thickness tests since line & ruler now use direct endpoint handles and StylePicker's 1-30px Stroke Width slider, while highlighter respects the restored 30px slider ceiling.
  // Old:
  // testWidgets('a resized line tracks the pointer one-for-one, like a shape', ...);
  // testWidgets('thickening from the bottom handle leaves the top edge put', ...);
  // testWidgets('thickening from the top handle leaves the bottom edge put', ...);
  // testWidgets('a ruler grows by what was dragged, not eight times it', ...);
  // testWidgets('the selection guide grows with the stroke it surrounds', ...);
  // testWidgets('a line can be dragged well past the old slider ceiling', ...);
  // for (final tool in const [CanvasTool.highlight, CanvasTool.ruler]) { ... }

  testWidgets('a ruler guide encloses its caps, not just its line', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final h = await _pump(tester, _flat(CanvasTool.ruler, strokeWidth: 6));
    addTearDown(() => h.dir.deleteSync(recursive: true));

    final canvas = _toCanvas(h.latest.single, h.box.size);
    final guide = AnnotationRenderer.boundingRect(canvas);
    final capHalf = AnnotationRenderer.rulerCapHalf(canvas);
    final lineY = canvas.startPoint!.dy;

    expect(
      guide.top,
      lessThanOrEqualTo(lineY - capHalf + 0.001),
      reason: 'the cap reaches capHalf above the line and must be inside',
    );
    expect(guide.bottom, greaterThanOrEqualTo(lineY + capHalf - 0.001));
  });

  testWidgets('highlight resize stays within the restored 30px slider ceiling', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final seed = Annotation(
      id: 'a1',
      tool: CanvasTool.highlight,
      color: const Color(0xFFFDE047),
      strokeWidth: 8,
      startPoint: const Offset(250, 450),
      points: const [Offset(250, 450), Offset(560, 452), Offset(900, 450)],
    );

    final h = await _pump(tester, seed);
    addTearDown(() => h.dir.deleteSync(recursive: true));

    final handles = await _selectAndGetHandles(tester, h);
    final corner = h.box.localToGlobal(handles.bottomRight);
    await _dragFromTo(tester, corner, corner + const Offset(0, 260));

    final canvas = _toCanvas(h.latest.single, h.box.size);
    expect(
      canvas.strokeWidth,
      closeTo(30.0, 0.01),
      reason:
          'highlighter has its slider restored, so drag thickness caps at 30px',
    );
  });

  testWidgets('a runaway drag still cannot move the pen weight', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final h = await _pump(tester, _pen(strokeWidth: 12));
    addTearDown(() => h.dir.deleteSync(recursive: true));

    final handles = await _selectAndGetHandles(tester, h);
    final corner = h.box.localToGlobal(handles.bottomRight);
    await _dragFromTo(tester, corner, corner + const Offset(0, 400));

    expect(h.latest.single.strokeWidth, closeTo(12, 0.01));
  });
}
