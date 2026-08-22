import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:snipsnap/models/annotation.dart';
import 'package:snipsnap/utils/constants.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/components/annotation_renderer.dart';
import 'package:snipsnap/views/editor_canvas.dart';

/// Everything the canvas emits is in image pixels, and so is everything it is
/// given, so ratios between a before and an after are projection-independent —
/// which is what these tests assert on.
class _Harness {
  _Harness(this.dir, this.imagePath, this.repaintKey);

  final Directory dir;
  final String imagePath;
  final GlobalKey repaintKey;

  List<Annotation> latest = const [];

  RenderBox get box => repaintKey.currentContext!.findRenderObject() as RenderBox;
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
    await tester.pumpWidget(StatefulBuilder(builder: (ctx, setState) {
      return SnipThemeScope(
        theme: SnipTheme.forMode(SnipThemeMode.dark),
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 700,
              height: 600,
              child: EditorCanvas(
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
                onAnnotationsUpdated: (list) => setState(() => harness.latest = list),
                onAnnotationsLiveUpdated: (list) => setState(() => harness.latest = list),
                repaintBoundaryKey: harness.repaintKey,
              ),
            ),
          ),
        ),
      );
    }));
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await tester.pump();
  });
  await tester.pumpAndSettle();
  return harness;
}

Future<void> _dragFromTo(WidgetTester tester, Offset from, Offset to) async {
  final gesture = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
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
  return AnnotationRenderer.selectionRect(_toCanvas(harness.latest.single, box.size));
}

Annotation _toCanvas(Annotation ann, Size canvasSize) {
  const imageSize = Size(1200, 900);
  final scale = math.min(canvasSize.width / imageSize.width,
      canvasSize.height / imageSize.height);
  final dx = (canvasSize.width - imageSize.width * scale) / 2;
  final dy = (canvasSize.height - imageSize.height * scale) / 2;
  Offset map(Offset p) => Offset(p.dx * scale + dx, p.dy * scale + dy);
  return ann.copyWith(
    startPoint: ann.startPoint == null ? null : map(ann.startPoint!),
    endPoint: ann.endPoint == null ? null : map(ann.endPoint!),
    points: ann.points.isEmpty ? null : ann.points.map(map).toList(),
    strokeWidth: ann.strokeWidth * scale,
  );
}

double _length(Annotation a) => (a.endPoint! - a.startPoint!).distance;
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

  for (final tool in const [CanvasTool.line, CanvasTool.arrow, CanvasTool.ruler]) {
    testWidgets('dragging along a ${tool.name} changes its length only',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final h = await _pump(tester, _flat(tool));
      addTearDown(() => h.dir.deleteSync(recursive: true));

      final before = h.latest.single;
      final handles = await _selectAndGetHandles(tester, h);

      // Purely horizontal, and the stroke is horizontal, so this is purely
      // "along".
      final corner = h.box.localToGlobal(handles.bottomRight);
      await _dragFromTo(tester, corner, corner + const Offset(160, 0));

      final after = h.latest.single;
      expect(_length(after) / _length(before), greaterThan(1.2),
          reason: 'dragging along the stroke must lengthen it');
      expect(after.strokeWidth, closeTo(before.strokeWidth, 0.01),
          reason: 'and must leave the thickness exactly alone');
      expect(_angle(after), closeTo(_angle(before), 0.02));
    });

    testWidgets('dragging across a ${tool.name} changes its thickness only',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final h = await _pump(tester, _flat(tool));
      addTearDown(() => h.dir.deleteSync(recursive: true));

      final before = h.latest.single;
      final handles = await _selectAndGetHandles(tester, h);

      // Straight down from the bottom-right handle: purely "across" a
      // horizontal stroke.
      final corner = h.box.localToGlobal(handles.bottomRight);
      await _dragFromTo(tester, corner, corner + const Offset(0, 90));

      final after = h.latest.single;
      expect(after.strokeWidth / before.strokeWidth, greaterThan(1.5),
          reason: 'dragging across the stroke must thicken it');
      expect(_length(after), closeTo(_length(before), 1.0),
          reason: 'and must leave the length exactly alone');
      expect(_angle(after), closeTo(_angle(before), 0.02),
          reason: 'a perpendicular drag must not swing it around');
    });
  }

  testWidgets('the top-left handle thickens when pulled the other way',
      (tester) async {
    // Outward is per-corner: the bottom-right handle thickens downward, the
    // top-left one upward. Getting the sign from the corner rather than
    // hard-coding it is what makes both work.
    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final h = await _pump(tester, _flat(CanvasTool.line));
    addTearDown(() => h.dir.deleteSync(recursive: true));

    final before = h.latest.single;
    final handles = await _selectAndGetHandles(tester, h);
    final corner = h.box.localToGlobal(handles.topLeft);
    await _dragFromTo(tester, corner, corner + const Offset(0, -90));

    expect(h.latest.single.strokeWidth / before.strokeWidth, greaterThan(1.5));
  });

  testWidgets('a vertical stroke lengthens when dragged vertically',
      (tester) async {
    // The axes are the stroke's own, not the screen's. A vertical line dragged
    // downward gets longer; screen-space axes would have fattened it instead.
    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final upright = Annotation(
      id: 'a1',
      tool: CanvasTool.line,
      color: const Color(0xFF000000),
      strokeWidth: 8,
      startPoint: const Offset(600, 200),
      endPoint: const Offset(602, 700),
    );
    final h = await _pump(tester, upright);
    addTearDown(() => h.dir.deleteSync(recursive: true));

    final before = h.latest.single;
    final handles = await _selectAndGetHandles(tester, h);
    final corner = h.box.localToGlobal(handles.bottomRight);
    await _dragFromTo(tester, corner, corner + const Offset(0, 110));

    final after = h.latest.single;
    expect(_length(after) / _length(before), greaterThan(1.2),
        reason: 'dragging along a vertical stroke lengthens it');
    expect(after.strokeWidth, closeTo(before.strokeWidth, 0.01));
  });

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
    expect(after.strokeWidth, closeTo(before.strokeWidth, 0.01),
        reason: 'a squiggle has no direction of its own, so its longer bounding '
            'axis stands in for one — dragging along it resizes, not thickens');
  });

  testWidgets('a pen stroke never changes weight, whichever way it is dragged',
      (tester) async {
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

      expect(h.latest.single.strokeWidth, closeTo(before.strokeWidth, 0.01),
          reason: 'dragging $drag must leave the pen weight untouched');
    }
  });

  testWidgets('a pen stroke scales in proportion from any corner drag',
      (tester) async {
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
    final afterW = (after.points.map((p) => p.dx).reduce(math.max)) -
        (after.points.map((p) => p.dx).reduce(math.min));
    final afterH = (after.points.map((p) => p.dy).reduce(math.max)) -
        (after.points.map((p) => p.dy).reduce(math.min));

    expect(afterH / beforeH, greaterThan(1.1),
        reason: 'a downward drag must grow it');
    expect(afterW / beforeW, closeTo(afterH / beforeH, 0.02),
        reason: 'and grow it by the same factor on both axes — proportionally, '
            'not stretched');
  });

  testWidgets('the highlighter resizes on both axes like the other strokes',
      (tester) async {
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
    expect((afterAlong.points.last - afterAlong.points.first).distance / beforeSpan,
        greaterThan(1.15),
        reason: 'dragging along the band lengthens it');
    expect(afterAlong.strokeWidth, closeTo(beforeAlong.strokeWidth, 0.5),
        reason: 'and leaves the band height alone');

    final across = await _pump(tester, marker());
    addTearDown(() => across.dir.deleteSync(recursive: true));
    final beforeAcross = across.latest.single;
    handles = await _selectAndGetHandles(tester, across);
    await _dragFromTo(
      tester,
      across.box.localToGlobal(handles.bottomRight),
      across.box.localToGlobal(handles.bottomRight) + const Offset(0, 70),
    );
    expect(across.latest.single.strokeWidth / beforeAcross.strokeWidth,
        greaterThan(1.5),
        reason: 'dragging across it makes the band taller');
  });

  testWidgets('a resized line tracks the pointer one-for-one, like a shape',
      (tester) async {
    // The bar this was measured against: dragging a shape's corner moves that
    // corner exactly onto the pointer. A stroke should feel the same — 120px
    // sideways adds 120px of length, 60px down adds 60px of weight — rather
    // than lagging behind by whatever the projection maths left over.
    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final h = await _pump(tester, _flat(CanvasTool.line, strokeWidth: 8));
    addTearDown(() => h.dir.deleteSync(recursive: true));

    final beforeCanvas = _toCanvas(h.latest.single, h.box.size);
    final beforeLength = _length(beforeCanvas);
    final beforeWidth = beforeCanvas.strokeWidth;

    final handles = await _selectAndGetHandles(tester, h);
    final corner = h.box.localToGlobal(handles.bottomRight);
    await _dragFromTo(tester, corner, corner + const Offset(120, 60));

    final after = _toCanvas(h.latest.single, h.box.size);
    expect(_length(after) - beforeLength, closeTo(120, 3),
        reason: 'the far end must land under the pointer, not short of it');
    expect(after.strokeWidth - beforeWidth, closeTo(60, 3),
        reason: 'and the edge must land under it too');
  });

  testWidgets('thickening from the bottom handle leaves the top edge put',
      (tester) async {
    // The report: holding the bottom of a line and dragging down grew it
    // upward as well, because a stroke straddles its own centre line. Dragging
    // a shape's bottom corner leaves its top where it was; this must match.
    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final h = await _pump(tester, _flat(CanvasTool.line, strokeWidth: 8));
    addTearDown(() => h.dir.deleteSync(recursive: true));

    double topEdge(Annotation a) =>
        math.min(a.startPoint!.dy, a.endPoint!.dy) - a.strokeWidth / 2;
    double bottomEdge(Annotation a) =>
        math.max(a.startPoint!.dy, a.endPoint!.dy) + a.strokeWidth / 2;

    final before = _toCanvas(h.latest.single, h.box.size);
    final handles = await _selectAndGetHandles(tester, h);
    final corner = h.box.localToGlobal(handles.bottomRight);
    await _dragFromTo(tester, corner, corner + const Offset(0, 80));

    final after = _toCanvas(h.latest.single, h.box.size);
    expect(after.strokeWidth - before.strokeWidth, closeTo(80, 4),
        reason: 'the drag must still thicken it one-for-one');
    expect(topEdge(after), closeTo(topEdge(before), 2),
        reason: 'the edge opposite the handle must not move');
    expect(bottomEdge(after) - bottomEdge(before), closeTo(80, 4),
        reason: 'and the held edge follows the pointer');
  });

  testWidgets('thickening from the top handle leaves the bottom edge put',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final h = await _pump(tester, _flat(CanvasTool.line, strokeWidth: 8));
    addTearDown(() => h.dir.deleteSync(recursive: true));

    double bottomEdge(Annotation a) =>
        math.max(a.startPoint!.dy, a.endPoint!.dy) + a.strokeWidth / 2;

    final before = _toCanvas(h.latest.single, h.box.size);
    final handles = await _selectAndGetHandles(tester, h);
    // topLeft, not topRight: the delete chip is positioned on the selection's
    // top-right corner and swallows the pointer before the handle sees it.
    final corner = h.box.localToGlobal(handles.topLeft);
    await _dragFromTo(tester, corner, corner + const Offset(0, -80));

    final after = _toCanvas(h.latest.single, h.box.size);
    expect(after.strokeWidth - before.strokeWidth, closeTo(80, 4));
    expect(bottomEdge(after), closeTo(bottomEdge(before), 2),
        reason: 'held from the top, the bottom edge is the one that is pinned');
  });

  testWidgets('a ruler grows by what was dragged, not eight times it',
      (tester) async {
    // The report: the ruler "expanded extremely", and upward as well as down.
    // Its caps and ticks reach 3.5x the stroke weight on *each* side of the
    // line, so treating a box change as a stroke-weight change multiplied every
    // drag by eight — and `boundingRect` counted only the weight, so the guide
    // was a fraction of the mark and the edge could not be pinned.
    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final h = await _pump(tester, _flat(CanvasTool.ruler, strokeWidth: 6));
    addTearDown(() => h.dir.deleteSync(recursive: true));

    final before = _toCanvas(h.latest.single, h.box.size);
    final beforeBounds = AnnotationRenderer.boundingRect(before);

    final handles = await _selectAndGetHandles(tester, h);
    final corner = h.box.localToGlobal(handles.bottomRight);
    await _dragFromTo(tester, corner, corner + const Offset(0, 80));

    final after = _toCanvas(h.latest.single, h.box.size);
    final afterBounds = AnnotationRenderer.boundingRect(after);

    expect(afterBounds.height - beforeBounds.height, closeTo(80, 5),
        reason: 'the drawn height must follow the pointer one-for-one');
    expect(afterBounds.top, closeTo(beforeBounds.top, 3),
        reason: 'and it must not climb upward while the bottom is held');
    expect(afterBounds.bottom - beforeBounds.bottom, closeTo(80, 5),
        reason: 'the held edge is the one that moves');
  });

  testWidgets('a ruler guide encloses its caps, not just its line',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final h = await _pump(tester, _flat(CanvasTool.ruler, strokeWidth: 6));
    addTearDown(() => h.dir.deleteSync(recursive: true));

    final canvas = _toCanvas(h.latest.single, h.box.size);
    final guide = AnnotationRenderer.boundingRect(canvas);
    final capHalf = AnnotationRenderer.rulerCapHalf(canvas);
    final lineY = canvas.startPoint!.dy;

    expect(guide.top, lessThanOrEqualTo(lineY - capHalf + 0.001),
        reason: 'the cap reaches capHalf above the line and must be inside');
    expect(guide.bottom, greaterThanOrEqualTo(lineY + capHalf - 0.001));
  });

  testWidgets('the selection guide grows with the stroke it surrounds',
      (tester) async {
    // The report: the line thickened but the box you grab to drag it did not,
    // so the handles ended up buried inside the mark. `boundingRect` returned a
    // bare `Rect.fromPoints` for two-point marks — pen, highlighter and curved
    // arrows all inflated by the stroke, straight lines did not.
    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final h = await _pump(tester, _flat(CanvasTool.line, strokeWidth: 8));
    addTearDown(() => h.dir.deleteSync(recursive: true));

    final beforeGuide = await _selectAndGetHandles(tester, h);
    final corner = h.box.localToGlobal(beforeGuide.bottomRight);
    await _dragFromTo(tester, corner, corner + const Offset(0, 120));

    final after = _toCanvas(h.latest.single, h.box.size);
    final afterGuide = AnnotationRenderer.selectionRect(after);

    expect(after.strokeWidth, greaterThan(20.0), reason: 'it must have thickened');
    expect(afterGuide.height, greaterThan(beforeGuide.height + 10),
        reason: 'the guide must have grown with it');
    // The mark has to sit inside its own guide, which is the whole point: the
    // stroke straddles the line by half its width on each side.
    final strokeTop = math.min(after.startPoint!.dy, after.endPoint!.dy) -
        after.strokeWidth / 2;
    final strokeBottom = math.max(after.startPoint!.dy, after.endPoint!.dy) +
        after.strokeWidth / 2;
    expect(afterGuide.top, lessThanOrEqualTo(strokeTop + 0.001));
    expect(afterGuide.bottom, greaterThanOrEqualTo(strokeBottom - 0.001));
  });

  testWidgets('a line can be dragged well past the old slider ceiling',
      (tester) async {
    // The report: dragging a line's edge stopped getting thicker almost
    // immediately. The clamp was the properties slider's own maximum of 30,
    // which is not thick on a large capture — and the line has no slider any
    // more, so nothing has to be able to reach the value it ends up at.
    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final h = await _pump(tester, _flat(CanvasTool.line, strokeWidth: 8));
    addTearDown(() => h.dir.deleteSync(recursive: true));

    final handles = await _selectAndGetHandles(tester, h);
    final corner = h.box.localToGlobal(handles.bottomRight);
    await _dragFromTo(tester, corner, corner + const Offset(0, 260));

    final canvas = _toCanvas(h.latest.single, h.box.size);
    expect(canvas.strokeWidth, greaterThan(30.0),
        reason: 'the slider ceiling must no longer cap a dragged line');
    expect(canvas.strokeWidth, lessThanOrEqualTo(240.0 + 0.001),
        reason: 'but a runaway drag still stops somewhere');
  });

  for (final tool in const [
    CanvasTool.arrow,
    CanvasTool.highlight,
    CanvasTool.ruler,
  ]) {
    testWidgets('${tool.name} can also be dragged past the old ceiling',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final seed = tool == CanvasTool.highlight
          ? Annotation(
              id: 'a1',
              tool: tool,
              color: const Color(0xFFFDE047),
              strokeWidth: 8,
              startPoint: const Offset(250, 450),
              points: const [Offset(250, 450), Offset(560, 452), Offset(900, 450)],
            )
          : _flat(tool, strokeWidth: 8);

      final h = await _pump(tester, seed);
      addTearDown(() => h.dir.deleteSync(recursive: true));

      final handles = await _selectAndGetHandles(tester, h);
      final corner = h.box.localToGlobal(handles.bottomRight);
      await _dragFromTo(tester, corner, corner + const Offset(0, 260));

      final canvas = _toCanvas(h.latest.single, h.box.size);
      expect(canvas.strokeWidth, greaterThan(30.0),
          reason: 'no slider caps ${tool.name} any more');
      expect(canvas.strokeWidth, lessThanOrEqualTo(240.0 + 0.001));
    });
  }

  testWidgets('a runaway drag still cannot move the pen weight', (tester) async {
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
