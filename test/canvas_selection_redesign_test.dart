// Gene - Nov, 23, 2026: Regression suite for canvas selection redesign, floating contextual action bar, direct linear/step handles, rotated resize, nudge/text persistence, and StylePicker controls.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:snipsnap/models/annotation.dart';
import 'package:snipsnap/utils/canvas_projection.dart';
import 'package:snipsnap/utils/constants.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/components/annotation_renderer.dart';
import 'package:snipsnap/views/components/style_picker.dart';
import 'package:snipsnap/views/editor_canvas.dart';

import 'support/base_image_settle.dart';

class _TestHarness {
  _TestHarness(this.dir, this.imagePath, this.repaintKey);

  final Directory dir;
  final String imagePath;
  final GlobalKey repaintKey;

  List<Annotation> latest = const [];
  String? selectedId;
  int deleteCallbackCount = 0;
  int frontCallbackCount = 0;
  int backCallbackCount = 0;
  late StateSetter setState;

  RenderBox get box =>
      repaintKey.currentContext!.findRenderObject() as RenderBox;
}

Future<_TestHarness> _pumpCanvas(
  WidgetTester tester, {
  required List<Annotation> seed,
  Size imageSize = const Size(2400, 1600),
  Size canvasWidgetSize = const Size(700, 600),
  CanvasTool activeTool = CanvasTool.select,
  double zoomScale = 1.0,
  bool wireParentCallbacks = false,
  bool syncSelectedIdFromParent = false,
}) async {
  final dir = Directory.systemTemp.createTempSync('snipsnap_sel_redesign');
  final imagePath = '${dir.path}/capture.png';
  final image = img.Image(
    width: imageSize.width.toInt(),
    height: imageSize.height.toInt(),
  );
  img.fill(image, color: img.ColorRgb8(245, 245, 245));
  File(imagePath).writeAsBytesSync(img.encodePng(image));

  final harness = _TestHarness(dir, imagePath, GlobalKey());
  harness.latest = List<Annotation>.from(seed);

  await tester.runAsync(() async {
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (ctx, setState) {
          harness.setState = setState;
          return SnipThemeScope(
            theme: SnipTheme.forMode(SnipThemeMode.light),
            child: MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: canvasWidgetSize.width,
                  height: canvasWidgetSize.height,
                  child: EditorCanvas(
                    key: ValueKey(imagePath),
                    imagePath: imagePath,
                    annotations: harness.latest,
                    activeTool: activeTool,
                    selectedAnnotationId: syncSelectedIdFromParent
                        ? harness.selectedId
                        : null,
                    activeColor: const Color(0xFFEF4444),
                    strokeWidth: 4,
                    fontSize: 18,
                    isFilled: false,
                    stepCounter: 1,
                    zoomScale: zoomScale,
                    onSelectAnnotation: (ann) {
                      setState(() => harness.selectedId = ann?.id);
                    },
                    onAnnotationAdded: (ann) {
                      setState(() => harness.latest = [...harness.latest, ann]);
                    },
                    onAnnotationsUpdated: (list) {
                      setState(() => harness.latest = list);
                    },
                    onAnnotationsLiveUpdated: (list) {
                      setState(() => harness.latest = list);
                    },
                    onStepCounterIncremented: (_) {},
                    onDeleteSelected: wireParentCallbacks
                        ? () {
                            harness.deleteCallbackCount++;
                            setState(() {
                              harness.latest = harness.latest
                                  .where((a) => a.id != harness.selectedId)
                                  .toList();
                              harness.selectedId = null;
                            });
                          }
                        : null,
                    onBringToFront: wireParentCallbacks
                        ? () => harness.frontCallbackCount++
                        : null,
                    onSendToBack: wireParentCallbacks
                        ? () => harness.backCallbackCount++
                        : null,
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

CanvasProjection _projectionFor(Size imageSize, RenderBox box) =>
    CanvasProjection(imageSize: imageSize, canvasSize: box.size);

Offset _imageToGlobal(Offset imgPt, Size imageSize, RenderBox box) {
  final p = _projectionFor(imageSize, box);
  return box.localToGlobal(p.toCanvas(imgPt));
}

Future<void> _dragGlobal(
  WidgetTester tester,
  Offset from,
  Offset to, {
  bool release = true,
}) async {
  final gesture = await tester.startGesture(
    from,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump(const Duration(milliseconds: 16));
  final dist = (to - from).distance;
  final dir = dist > 0 ? (to - from) / dist : Offset.zero;
  await gesture.moveTo(from + dir * 2);
  await tester.pump(const Duration(milliseconds: 16));
  final steps = math.max(10, (dist / 4).round());
  for (var i = 1; i <= steps; i++) {
    await gesture.moveTo(Offset.lerp(from, to, i / steps)!);
    await tester.pump(const Duration(milliseconds: 16));
  }
  if (release) {
    await gesture.up();
    await tester.pumpAndSettle();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Floating contextual action bar proximity & layout', () {
    testWidgets(
      'action bar sits directly near a bottom-right arrow on a downscaled high-res capture without overlapping handles',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(900, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        const imageSize = Size(2400, 1600);
        final arrow = Annotation(
          id: 'arrow-br',
          tool: CanvasTool.arrow,
          color: const Color(0xFFEF4444),
          strokeWidth: 8,
          startPoint: const Offset(1750, 1280),
          endPoint: const Offset(2280, 1420),
        );

        final h = await _pumpCanvas(
          tester,
          seed: [arrow],
          imageSize: imageSize,
        );
        addTearDown(() => h.dir.deleteSync(recursive: true));

        final proj = _projectionFor(imageSize, h.box);
        expect(proj.scale, greaterThan(2.5));

        final canvasAnn = arrow.mappedToCanvasSpace(proj);
        final midGlobal = h.box.localToGlobal(
          (canvasAnn.startPoint! + canvasAnn.endPoint!) / 2,
        );
        await tester.tapAt(midGlobal, kind: PointerDeviceKind.mouse);
        await tester.pumpAndSettle();

        final barFinder = find.byKey(const ValueKey('selection-action-bar'));
        expect(barFinder, findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(InteractiveViewer),
            matching: barFinder,
          ),
          findsNothing,
        );

        final barRect = tester.getRect(barFinder);
        final startGlobal = _imageToGlobal(arrow.startPoint!, imageSize, h.box);
        final endGlobal = _imageToGlobal(arrow.endPoint!, imageSize, h.box);
        final apexGlobal = h.box.localToGlobal(
          AnnotationRenderer.arrowCurveApex(canvasAnn),
        );
        final selBounds = AnnotationRenderer.rotatedSelectionBounds(canvasAnn);
        final arrowTopLeftGlobal = h.box.localToGlobal(selBounds.topLeft);
        final arrowBottomRightGlobal = h.box.localToGlobal(
          selBounds.bottomRight,
        );
        final arrowBoundsGlobal = Rect.fromPoints(
          arrowTopLeftGlobal,
          arrowBottomRightGlobal,
        );

        expect(
          (barRect.center.dx - arrowBoundsGlobal.center.dx).abs(),
          lessThan(85.0),
          reason:
              'action bar must be horizontally centered near the arrow, not shifted toward top-left',
        );
        final verticalGap = math.min(
          (barRect.top - arrowBoundsGlobal.bottom).abs(),
          (arrowBoundsGlobal.top - barRect.bottom).abs(),
        );
        expect(
          verticalGap,
          lessThan(65.0),
          reason: 'action bar must stay tightly attached to the arrow bounds',
        );

        expect(barRect.inflate(2.0).contains(startGlobal), isFalse);
        expect(barRect.inflate(2.0).contains(endGlobal), isFalse);
        expect(barRect.inflate(2.0).contains(apexGlobal), isFalse);
      },
    );

    testWidgets('action bar stays tight to a selected arrow when zoomed in 2x', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(900, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      const imageSize = Size(2400, 1600);
      final arrow = Annotation(
        id: 'arrow-center',
        tool: CanvasTool.arrow,
        color: const Color(0xFFEF4444),
        strokeWidth: 8,
        startPoint: const Offset(1000, 750),
        endPoint: const Offset(1400, 850),
      );

      final h = await _pumpCanvas(
        tester,
        seed: [arrow],
        imageSize: imageSize,
        zoomScale: 2.0,
      );
      addTearDown(() => h.dir.deleteSync(recursive: true));

      final proj = _projectionFor(imageSize, h.box);
      final canvasAnn = arrow.mappedToCanvasSpace(proj);
      final midGlobal = h.box.localToGlobal(
        (canvasAnn.startPoint! + canvasAnn.endPoint!) / 2,
      );

      await tester.tapAt(midGlobal, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();

      final barFinder = find.byKey(const ValueKey('selection-action-bar'));
      expect(barFinder, findsOneWidget);
      final barRect = tester.getRect(barFinder);
      final selBounds = AnnotationRenderer.rotatedSelectionBounds(
        canvasAnn,
        viewScale: 2.0,
      );
      final arrowBoundsGlobal = Rect.fromPoints(
        h.box.localToGlobal(selBounds.topLeft),
        h.box.localToGlobal(selBounds.bottomRight),
      );
      expect(
        (barRect.center.dx - arrowBoundsGlobal.center.dx).abs(),
        lessThan(65.0),
      );
      expect(
        (barRect.top - arrowBoundsGlobal.bottom).abs(),
        lessThan(40.0),
      );
    });
  });

  group('Action bar buttons, visibility, and synchronization', () {
    testWidgets(
      'duplicate, front, back, straighten, reset-rotation, edit-text, and delete actions work and hide mid-drag',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(900, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        const imageSize = Size(1200, 900);
        final curvedArrow = Annotation(
          id: 'a-curved',
          tool: CanvasTool.arrow,
          color: const Color(0xFFEF4444),
          strokeWidth: 6,
          startPoint: const Offset(250, 350),
          endPoint: const Offset(750, 350),
          controlPoint: const Offset(500, 220),
        );
        final rotatedBox = Annotation(
          id: 'r-rot',
          tool: CanvasTool.shape,
          color: const Color(0xFF0EA5E9),
          strokeWidth: 4,
          startPoint: const Offset(250, 520),
          endPoint: const Offset(450, 620),
          rotation: math.pi / 4,
        );
        final textItem = Annotation(
          id: 't-1',
          tool: CanvasTool.text,
          color: const Color(0xFF10B981),
          text: 'Hello',
          startPoint: const Offset(700, 600),
          fontSize: 24,
        );

        final h = await _pumpCanvas(
          tester,
          seed: [curvedArrow, rotatedBox, textItem],
          imageSize: imageSize,
          syncSelectedIdFromParent: true,
        );
        addTearDown(() => h.dir.deleteSync(recursive: true));

        final proj = _projectionFor(imageSize, h.box);

        // 1. Select curved arrow: Straighten visible; Reset-rotation & Edit-text hidden.
        final arrowCanvas = curvedArrow.mappedToCanvasSpace(proj);
        final arrowApexGlobal = h.box.localToGlobal(
          AnnotationRenderer.arrowCurveApex(arrowCanvas),
        );
        await tester.tapAt(arrowApexGlobal, kind: PointerDeviceKind.mouse);
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('selection-action-straighten')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('selection-action-reset-rotation')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('selection-action-edit-text')),
          findsNothing,
        );

        // Action bar hides while dragging.
        final dragGesture = await tester.startGesture(
          arrowApexGlobal,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump(const Duration(milliseconds: 16));
        await dragGesture.moveTo(arrowApexGlobal + const Offset(20, 20));
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          find.byKey(const ValueKey('selection-action-bar')),
          findsNothing,
          reason: 'action bar must hide while actively transforming',
        );
        await dragGesture.up();
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('selection-action-bar')),
          findsOneWidget,
        );

        // Straighten arrow via pill button.
        await tester.tap(
          find.byKey(const ValueKey('selection-action-straighten')),
        );
        await tester.pumpAndSettle();
        expect(
          h.latest.firstWhere((a) => a.id == 'a-curved').controlPoint,
          isNull,
        );
        expect(
          find.byKey(const ValueKey('selection-action-straighten')),
          findsNothing,
        );

        // Bring to front & send to back.
        await tester.tap(find.byKey(const ValueKey('selection-action-front')));
        await tester.pumpAndSettle();
        expect(h.latest.last.id, 'a-curved');

        await tester.tap(find.byKey(const ValueKey('selection-action-back')));
        await tester.pumpAndSettle();
        expect(h.latest.first.id, 'a-curved');

        // Duplicate.
        await tester.tap(
          find.byKey(const ValueKey('selection-action-duplicate')),
        );
        await tester.pumpAndSettle();
        expect(h.latest, hasLength(4));

        // Delete the duplicate via action bar.
        await tester.tap(find.byKey(const ValueKey('selection-action-delete')));
        await tester.pumpAndSettle();
        expect(h.latest, hasLength(3));
        expect(
          find.byKey(const ValueKey('selection-action-bar')),
          findsNothing,
        );

        // 2. Select rotated box -> Reset Rotation visible & works.
        final boxCenterGlobal = _imageToGlobal(
          const Offset(350, 570),
          imageSize,
          h.box,
        );
        await tester.tapAt(boxCenterGlobal, kind: PointerDeviceKind.mouse);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('selection-action-reset-rotation')),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const ValueKey('selection-action-reset-rotation')),
        );
        await tester.pumpAndSettle();
        expect(h.latest.firstWhere((a) => a.id == 'r-rot').rotation, 0.0);

        // 3. Select text -> Edit Text visible & opens inline TextField.
        final textBounds = AnnotationRenderer.boundingRect(
          textItem.mappedToCanvasSpace(proj),
        );
        await tester.tapAt(
          h.box.localToGlobal(textBounds.center),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('selection-action-edit-text')),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const ValueKey('selection-action-edit-text')),
        );
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsOneWidget);
      },
    );

    testWidgets(
      'delegates Delete to onDeleteSelected when wired and clears chrome when parent clears selectedAnnotationId',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(900, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        const imageSize = Size(1200, 900);
        final rectAnn = Annotation(
          id: 'rect-1',
          tool: CanvasTool.shape,
          color: const Color(0xFFEF4444),
          fill: true,
          strokeWidth: 4,
          startPoint: const Offset(300, 300),
          endPoint: const Offset(600, 500),
        );

        final h = await _pumpCanvas(
          tester,
          seed: [rectAnn],
          imageSize: imageSize,
          wireParentCallbacks: true,
          syncSelectedIdFromParent: true,
        );
        addTearDown(() => h.dir.deleteSync(recursive: true));

        await tester.tapAt(
          _imageToGlobal(const Offset(450, 400), imageSize, h.box),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('selection-action-bar')),
          findsOneWidget,
        );

        // Inbound selectedAnnotationId: null (e.g. StylePicker Deselect) hides chrome immediately.
        h.setState(() => h.selectedId = null);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('selection-action-bar')),
          findsNothing,
        );

        // Re-select and delete via action bar -> delegates to onDeleteSelected.
        await tester.tapAt(
          _imageToGlobal(const Offset(450, 400), imageSize, h.box),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('selection-action-delete')));
        await tester.pumpAndSettle();
        expect(h.deleteCallbackCount, 1);
        expect(h.latest, isEmpty);
      },
    );
  });

  group('Rotated resize, step handle, nudge & double-click persistence', () {
    testWidgets(
      'resizing a 90°-rotated shape moves the dragged handle in screen space and anchors the opposite corner',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(900, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        const imageSize = Size(1200, 900);
        final shape = Annotation(
          id: 'rot-shape',
          tool: CanvasTool.shape,
          color: const Color(0xFF0EA5E9),
          fill: true,
          strokeWidth: 4,
          startPoint: const Offset(400, 350),
          endPoint: const Offset(700, 500),
          rotation: math.pi / 2,
        );

        final h = await _pumpCanvas(tester, seed: [shape], imageSize: imageSize);
        addTearDown(() => h.dir.deleteSync(recursive: true));

        final proj = _projectionFor(imageSize, h.box);
        final beforeCanvas = shape.mappedToCanvasSpace(proj);
        final beforeSel = AnnotationRenderer.selectionRect(beforeCanvas);

        await tester.tapAt(
          h.box.localToGlobal(
            AnnotationRenderer.boundingRect(beforeCanvas).center,
          ),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();

        // Grab rotated bottomRight handle and drag straight down 80px on screen.
        final draggedLocal = beforeSel.bottomRight;
        final oppositeLocal = AnnotationRenderer.boundingRect(beforeCanvas)
            .topLeft;
        final draggedCanvasBefore = AnnotationRenderer.toCanvasSpace(
          beforeCanvas,
          draggedLocal,
        );
        final oppositeCanvasBefore = AnnotationRenderer.toCanvasSpace(
          beforeCanvas,
          oppositeLocal,
        );

        final dragStartGlobal = h.box.localToGlobal(draggedCanvasBefore);
        await _dragGlobal(
          tester,
          dragStartGlobal,
          dragStartGlobal + const Offset(0, 80),
        );

        final afterCanvas = h.latest.single.mappedToCanvasSpace(proj);
        final afterLocalBounds = AnnotationRenderer.boundingRect(afterCanvas);
        final draggedCanvasAfter = AnnotationRenderer.toCanvasSpace(
          afterCanvas,
          afterLocalBounds.bottomRight,
        );
        final oppositeCanvasAfter = AnnotationRenderer.toCanvasSpace(
          afterCanvas,
          afterLocalBounds.topLeft,
        );

        expect(
          oppositeCanvasAfter.dx,
          closeTo(oppositeCanvasBefore.dx, 4.0),
        );
        expect(
          oppositeCanvasAfter.dy,
          closeTo(oppositeCanvasBefore.dy, 4.0),
          reason: 'opposite corner must remain stationary in canvas space',
        );
        expect(
          draggedCanvasAfter.dy -
              AnnotationRenderer.toCanvasSpace(
                beforeCanvas,
                AnnotationRenderer.boundingRect(beforeCanvas).bottomRight,
              ).dy,
          closeTo(80.0, 5.0),
          reason: 'dragged rotated handle must follow screen drag direction',
        );
      },
    );

    testWidgets('step marker single scale handle resizes badge fontSize', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(900, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      const imageSize = Size(1200, 900);
      final step = Annotation(
        id: 'step-1',
        tool: CanvasTool.stepMarker,
        color: const Color(0xFFEF4444),
        startPoint: const Offset(500, 400),
        stepNumber: 1,
        fontSize: 20,
      );

      final h = await _pumpCanvas(tester, seed: [step], imageSize: imageSize);
      addTearDown(() => h.dir.deleteSync(recursive: true));

      final proj = _projectionFor(imageSize, h.box);
      final canvasStep = step.mappedToCanvasSpace(proj);
      await tester.tapAt(
        h.box.localToGlobal(canvasStep.startPoint!),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('selection-action-reset-rotation')),
        findsNothing,
      );

      final scaleHandleGlobal = h.box.localToGlobal(
        AnnotationRenderer.stepScaleHandlePosition(canvasStep),
      );
      await _dragGlobal(
        tester,
        scaleHandleGlobal,
        scaleHandleGlobal + const Offset(24, 24),
      );

      expect(h.latest.single.fontSize, greaterThan(35.0));
    });

    testWidgets(
      'keyboard arrow nudge and double-click text edit in Select tool persist across rebuild frames',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(900, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        const imageSize = Size(1200, 900);
        final textAnn = Annotation(
          id: 'txt-1',
          tool: CanvasTool.text,
          color: const Color(0xFF141414),
          text: 'Initial',
          startPoint: const Offset(400, 400),
          fontSize: 24,
        );

        final h = await _pumpCanvas(
          tester,
          seed: [textAnn],
          imageSize: imageSize,
          activeTool: CanvasTool.select,
        );
        addTearDown(() => h.dir.deleteSync(recursive: true));

        final proj = _projectionFor(imageSize, h.box);
        final bounds = AnnotationRenderer.boundingRect(
          textAnn.mappedToCanvasSpace(proj),
        );
        final centerGlobal = h.box.localToGlobal(bounds.center);

        // Select and nudge right with Shift (10px).
        await tester.tapAt(centerGlobal, kind: PointerDeviceKind.mouse);
        await tester.pumpAndSettle();

        final beforeX = h.latest.single.startPoint!.dx;
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 50));

        expect(
          h.latest.single.startPoint!.dx,
          greaterThan(beforeX + 5.0),
          reason: 'keyboard nudge must persist after parent rebuild',
        );

        // Double-click text while CanvasTool.select is active -> opens inline editor and saves.
        final updatedBounds = AnnotationRenderer.boundingRect(
          h.latest.single.mappedToCanvasSpace(proj),
        );
        final updatedCenter = h.box.localToGlobal(updatedBounds.center);
        await tester.tapAt(updatedCenter, kind: PointerDeviceKind.mouse);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tapAt(updatedCenter, kind: PointerDeviceKind.mouse);
        await tester.pumpAndSettle();

        expect(find.byType(TextField), findsOneWidget);
        await tester.enterText(find.byType(TextField), 'Edited Label');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 50));

        expect(h.latest.single.text, 'Edited Label');
      },
    );
  });

  group('Curved arrow geometry & StylePicker controls', () {
    test(
      'arrowCurveApex/controlPointForApex round-trips and curved boundingRect tightly fits the arc',
      () {
        const start = Offset(0, 0);
        const end = Offset(100, 0);
        const desiredApex = Offset(50, 100);
        final cp = AnnotationRenderer.controlPointForApex(
          start,
          end,
          desiredApex,
        );
        expect(cp, const Offset(50, 200));

        final arrow = Annotation(
          id: 'c1',
          tool: CanvasTool.arrow,
          color: const Color(0xFFEF4444),
          strokeWidth: 4,
          startPoint: start,
          endPoint: end,
          controlPoint: cp,
        );
        expect(AnnotationRenderer.arrowCurveApex(arrow), desiredApex);

        final bounds = AnnotationRenderer.boundingRect(arrow);
        expect(bounds.bottom, greaterThanOrEqualTo(102.0));
        expect(
          bounds.bottom,
          lessThan(130.0),
          reason:
              'boundingRect must enclose the actual curve apex (~102), not jump out to raw controlPoint (200)',
        );
      },
    );

    testWidgets(
      'StylePicker restores LINE THICKNESS for arrow, line, ruler, highlight and exposes Duplicate on selection',
      (tester) async {
        for (final tool in const [
          CanvasTool.arrow,
          CanvasTool.line,
          CanvasTool.ruler,
          CanvasTool.highlight,
        ]) {
          await tester.pumpWidget(
            SnipThemeScope(
              theme: SnipTheme.forMode(SnipThemeMode.light),
              child: MaterialApp(
                home: Scaffold(
                  body: StylePicker(
                    selectedColor: const Color(0xFFEF4444),
                    onColorChanged: (_) {},
                    strokeWidth: 4,
                    onStrokeWidthChanged: (_) {},
                    opacity: 1,
                    onOpacityChanged: (_) {},
                    fontSize: 18,
                    onFontSizeChanged: (_) {},
                    isFilled: false,
                    onFillChanged: (_) {},
                    activeTool: tool,
                  ),
                ),
              ),
            ),
          );
          tester.takeException();
          expect(
            find.text('LINE THICKNESS'),
            findsOneWidget,
            reason: '$tool must expose LINE THICKNESS controls',
          );
        }

        var duplicateTapped = false;
        await tester.pumpWidget(
          SnipThemeScope(
            theme: SnipTheme.forMode(SnipThemeMode.light),
            child: MaterialApp(
              home: Scaffold(
                body: StylePicker(
                  selectedColor: const Color(0xFFEF4444),
                  onColorChanged: (_) {},
                  strokeWidth: 4,
                  onStrokeWidthChanged: (_) {},
                  opacity: 1,
                  onOpacityChanged: (_) {},
                  fontSize: 18,
                  onFontSizeChanged: (_) {},
                  isFilled: false,
                  onFillChanged: (_) {},
                  activeTool: CanvasTool.arrow,
                  selectedAnnotation: Annotation(
                    id: 'a1',
                    tool: CanvasTool.arrow,
                    color: const Color(0xFFEF4444),
                    startPoint: const Offset(0, 0),
                    endPoint: const Offset(100, 0),
                  ),
                  onDuplicateSelected: () => duplicateTapped = true,
                  onDeleteSelected: () {},
                ),
              ),
            ),
          ),
        );
        tester.takeException();
        final dupIcon = find.byIcon(Icons.copy_rounded);
        expect(dupIcon, findsOneWidget);
        await tester.tap(dupIcon);
        await tester.pump();
        expect(duplicateTapped, isTrue);
      },
    );
  });
}
