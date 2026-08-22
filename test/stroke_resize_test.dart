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
  await gesture.moveTo(from + const Offset(2, 2));
  await tester.pump(const Duration(milliseconds: 16));
  for (var i = 1; i <= 12; i++) {
    await gesture.moveTo(Offset.lerp(from, to, i / 12)!);
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

Annotation _twoPoint(CanvasTool tool, {double strokeWidth = 8}) => Annotation(
      id: 'a1',
      tool: tool,
      color: const Color(0xFF000000),
      strokeWidth: strokeWidth,
      startPoint: const Offset(300, 300),
      endPoint: const Offset(800, 620),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => TestWidgetsFlutterBinding.ensureInitialized());

  for (final tool in const [CanvasTool.line, CanvasTool.arrow, CanvasTool.ruler]) {
    testWidgets('${tool.name} gets thicker as it gets longer', (tester) async {
      // The report: dragging a handle only changed the length, leaving a hairline
      // stroke stretched across the capture. Size and thickness are one property
      // for a stroke, so a resize has to carry both.
      await tester.binding.setSurfaceSize(const Size(900, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final h = await _pump(tester, _twoPoint(tool));
      addTearDown(() => h.dir.deleteSync(recursive: true));

      final before = h.latest.single;
      final handles = await _selectAndGetHandles(tester, h);

      // Drag the bottom-right handle away from the top-left anchor, along the
      // stroke's own direction.
      final corner = h.box.localToGlobal(handles.bottomRight);
      final anchor = h.box.localToGlobal(handles.topLeft);
      final target = anchor + (corner - anchor) * 1.6;
      await _dragFromTo(tester, corner, target);

      final after = h.latest.single;
      final lengthRatio = _length(after) / _length(before);
      final strokeRatio = after.strokeWidth / before.strokeWidth;

      expect(lengthRatio, greaterThan(1.2), reason: 'the drag must lengthen it');
      expect(strokeRatio, closeTo(lengthRatio, 0.05),
          reason: 'thickness must scale with length, not stay put');
    });
  }

  testWidgets('an arrow keeps its angle when a handle is dragged sideways',
      (tester) async {
    // The other half of the report: dragging vertically "is like rotating".
    // A near-horizontal arrow has a bounding box a couple of pixels tall, so
    // the old per-axis scaling turned any vertical movement into an enormous
    // change of angle.
    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final flat = Annotation(
      id: 'a1',
      tool: CanvasTool.arrow,
      color: const Color(0xFF000000),
      strokeWidth: 6,
      startPoint: const Offset(250, 450),
      endPoint: const Offset(900, 452),
    );
    final h = await _pump(tester, flat);
    addTearDown(() => h.dir.deleteSync(recursive: true));

    final before = h.latest.single;
    final handles = await _selectAndGetHandles(tester, h);

    // Straight down from the bottom-right handle: purely perpendicular to a
    // horizontal arrow.
    final corner = h.box.localToGlobal(handles.bottomRight);
    await _dragFromTo(tester, corner, corner + const Offset(0, 160));

    final after = h.latest.single;
    expect(_angle(after), closeTo(_angle(before), 0.02),
        reason: 'a perpendicular drag must not swing the arrow around');
  });

  testWidgets('a pen stroke scales its points and its thickness together',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final pen = Annotation(
      id: 'a1',
      tool: CanvasTool.pen,
      color: const Color(0xFF000000),
      strokeWidth: 5,
      startPoint: const Offset(300, 300),
      points: const [
        Offset(300, 300),
        Offset(420, 380),
        Offset(560, 340),
        Offset(700, 520),
      ],
    );
    final h = await _pump(tester, pen);
    addTearDown(() => h.dir.deleteSync(recursive: true));

    final before = h.latest.single;
    final beforeSpan = (before.points.last - before.points.first).distance;
    final handles = await _selectAndGetHandles(tester, h);

    final corner = h.box.localToGlobal(handles.bottomRight);
    final anchor = h.box.localToGlobal(handles.topLeft);
    await _dragFromTo(tester, corner, anchor + (corner - anchor) * 1.5);

    final after = h.latest.single;
    expect(after.points, hasLength(before.points.length));
    final afterSpan = (after.points.last - after.points.first).distance;
    final spanRatio = afterSpan / beforeSpan;

    expect(spanRatio, greaterThan(1.15));
    expect(after.strokeWidth / before.strokeWidth, closeTo(spanRatio, 0.05),
        reason: 'a freehand stroke scales its weight with its size too');
  });

  testWidgets('thickness stops at the slider maximum', (tester) async {
    // Whatever a resize produces has to remain adjustable by the properties
    // slider afterwards, so it stays inside the slider's own range.
    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final h = await _pump(tester, _twoPoint(CanvasTool.line, strokeWidth: 26));
    addTearDown(() => h.dir.deleteSync(recursive: true));

    final handles = await _selectAndGetHandles(tester, h);
    final corner = h.box.localToGlobal(handles.bottomRight);
    final anchor = h.box.localToGlobal(handles.topLeft);
    await _dragFromTo(tester, corner, anchor + (corner - anchor) * 6);

    // Image-space stroke width maps to canvas units by the projection scale;
    // the clamp is applied in canvas units, so convert before comparing.
    final canvas = _toCanvas(h.latest.single, h.box.size);
    expect(canvas.strokeWidth, lessThanOrEqualTo(30.0 + 0.001));
  });
}
