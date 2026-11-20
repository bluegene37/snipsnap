// Gene - Nov, 20, 2026: Regression and integration tests for long panoramic canvas navigation and Rust FFI RGBA ops.
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:snipsnap/models/annotation.dart';
import 'package:snipsnap/services/native/rust_image_core.dart';
import 'package:snipsnap/utils/canvas_projection.dart';
import 'package:snipsnap/utils/constants.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/components/annotation_renderer.dart';
import 'package:snipsnap/views/editor_canvas.dart';

import 'support/base_image_settle.dart';

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

  group('Panoramic Bounds & MaxZoom Math', () {
    test(
      'keeps 4.0 maxZoom for regular capture and unlocks for tall images',
      () {
        final normalMax = computeEffectiveMaxZoom(
          viewportSize: const Size(600, 500),
          imageSize: const Size(1600, 900),
        );
        expect(normalMax, 4.0);

        final tallMax = computeEffectiveMaxZoom(
          viewportSize: const Size(1200, 800),
          imageSize: const Size(1000, 12000),
        );
        // fitScale = 760 / 12000 = 0.06333 => 1:1 native ~ 15.79x, *2.5 ~ 39.47x
        expect(tallMax, greaterThan(15.0));
        expect(tallMax, lessThanOrEqualTo(48.0));
      },
    );

    test(
      'pins X centered with zero void drift when tall image fits width and constrains Y',
      () {
        const viewport = Size(1200, 800);
        const image = Size(800, 9000);
        const scale = 6.0;

        final bounds = computePanoramicBounds(
          viewportSize: viewport,
          imageSize: image,
          scale: scale,
        );
        expect(bounds.canPanX, isFalse);
        expect(bounds.canPanY, isTrue);
        expect(bounds.minTx, closeTo(bounds.maxTx, 0.001));

        // Attempt extreme horizontal & vertical drift.
        final driftedRight = Matrix4.identity()
          ..translateByDouble(5000.0, 2000.0, 0.0, 1.0)
          ..scaleByDouble(scale, scale, scale, 1.0);
        final clampedTop = constrainCanvasTransform(
          matrix: driftedRight,
          viewportSize: viewport,
          imageSize: image,
        );
        expect(clampedTop.storage[12], closeTo(bounds.minTx, 0.01));
        expect(clampedTop.storage[13], closeTo(bounds.maxTy, 0.01));

        final driftedBottomLeft = Matrix4.identity()
          ..translateByDouble(-9000.0, -90000.0, 0.0, 1.0)
          ..scaleByDouble(scale, scale, scale, 1.0);
        final clampedBottom = constrainCanvasTransform(
          matrix: driftedBottomLeft,
          viewportSize: viewport,
          imageSize: image,
        );
        expect(clampedBottom.storage[12], closeTo(bounds.minTx, 0.01));
        expect(clampedBottom.storage[13], closeTo(bounds.minTy, 0.01));
      },
    );

    test('preserves normal 1600x900 viewport pan clamping at zoomed scale', () {
      const viewport = Size(600, 500);
      const image = Size(1600, 900);
      const scale = 2.0;

      final bounds = computePanoramicBounds(
        viewportSize: viewport,
        imageSize: image,
        scale: scale,
      );
      expect(bounds.canPanX, isTrue);
      expect(bounds.canPanY, isTrue);
      expect(bounds.maxTx, lessThanOrEqualTo(0.001));
      expect(bounds.maxTy, lessThanOrEqualTo(0.001));
      expect(bounds.minTy, greaterThanOrEqualTo(500.0 - 500.0 * scale - 0.001));
    });
  });

  group('Long Image EditorCanvas UX', () {
    late Directory tempDir;
    late String tallPngPath;
    late GlobalKey repaintKey;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('snipsnap_long_canvas_');
      tallPngPath = '${tempDir.path}/tall_800x9000.png';
      // 800x9000 striped PNG so image decoding, Fit/1:1, and scrolling are exercised.
      final tall = img.Image(width: 800, height: 9000);
      img.fill(tall, color: img.ColorRgba8(245, 245, 250, 255));
      for (var y = 0; y < 9000; y += 500) {
        img.fillRect(
          tall,
          x1: 0,
          y1: y,
          x2: 799,
          y2: (y + 39).clamp(0, 8999),
          color: img.ColorRgba8(30, 90, 200, 255),
        );
      }
      File(tallPngPath).writeAsBytesSync(img.encodePng(tall, level: 1));
      repaintKey = GlobalKey();
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    testWidgets(
      'auto-zooms tall capture to 1:1 without horizontal void drift and responds to keyboard + HUD chips',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1200, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        double? reportedMaxZoom;
        double currentZoom = 1.0;

        await tester.runAsync(() async {
          await tester.pumpWidget(
            SnipThemeScope(
              theme: SnipTheme.forMode(SnipThemeMode.dark),
              child: MaterialApp(
                home: Scaffold(
                  body: SizedBox(
                    width: 1200,
                    height: 800,
                    child: EditorCanvas(
                      imagePath: tallPngPath,
                      annotations: const [],
                      activeTool: CanvasTool.select,
                      activeColor: const Color(0xFF000000),
                      strokeWidth: 4,
                      fontSize: 16,
                      isFilled: false,
                      stepCounter: 1,
                      onAnnotationAdded: (_) {},
                      onStepCounterIncremented: (_) {},
                      onZoomScaleChanged: (z) => currentZoom = z,
                      onMaxZoomChanged: (m) => reportedMaxZoom = m,
                      repaintBoundaryKey: repaintKey,
                    ),
                  ),
                ),
              ),
            ),
          );
          await settleBaseImage(tester);
        });
        await tester.pumpAndSettle();

        final initialScale = _scale(tester);
        final initialTranslation = _translation(tester);

        // Dynamic maxZoom > 4.0 and initial panoramic auto-zoom unlocked to 1:1 native (~11.84x).
        expect(reportedMaxZoom, isNotNull);
        expect(reportedMaxZoom!, greaterThan(15.0));
        expect(initialScale, greaterThan(4.0));
        expect(currentZoom, closeTo(initialScale, 0.01));
        expect(find.text('Fit'), findsOneWidget);
        expect(find.text('1:1'), findsOneWidget);
        expect(find.textContaining('% native'), findsOneWidget);

        // Top edge of padded image rect (y = 20) sits flush at viewport y = 20.
        expect(20.0 * initialScale + initialTranslation.dy, closeTo(20.0, 1.0));

        // Horizontal scroll attempts produce zero X drift because width fits inside viewport.
        await _scroll(tester, const Offset(600, 400), const Offset(350, 0));
        expect(
          _translation(tester).dx,
          closeTo(initialTranslation.dx, 0.01),
          reason: 'narrow tall image must stay centered without void drift',
        );

        // Vertical scroll wheel moves viewport downward along Y only.
        await _scroll(tester, const Offset(600, 400), const Offset(0, 400));
        final afterWheel = _translation(tester);
        expect(afterWheel.dx, closeTo(initialTranslation.dx, 0.01));
        expect(afterWheel.dy, lessThan(initialTranslation.dy - 300.0));

        // Keyboard PageDown, End, Home navigation works cleanly.
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await tester.pumpAndSettle();
        final afterPageDown = _translation(tester);
        expect(afterPageDown.dy, lessThan(afterWheel.dy - 300.0));
        expect(afterPageDown.dx, closeTo(initialTranslation.dx, 0.01));

        await tester.sendKeyEvent(LogicalKeyboardKey.end);
        await tester.pumpAndSettle();
        final bounds = computePanoramicBounds(
          viewportSize: const Size(1200, 800),
          imageSize: const Size(800, 9000),
          scale: initialScale,
        );
        expect(_translation(tester).dy, closeTo(bounds.minTy, 1.0));

        await tester.sendKeyEvent(LogicalKeyboardKey.home);
        await tester.pumpAndSettle();
        expect(_translation(tester).dy, closeTo(bounds.maxTy, 1.0));

        // [Fit] resets scale to 1.0; [1:1] restores crisp native scale.
        await tester.tap(find.text('Fit'));
        await tester.pumpAndSettle();
        expect(_scale(tester), closeTo(1.0, 0.01));
        expect(_translation(tester), Offset.zero);

        await tester.tap(find.text('1:1'));
        await tester.pumpAndSettle();
        expect(_scale(tester), greaterThan(4.0));
        expect(
          20.0 * _scale(tester) + _translation(tester).dy,
          closeTo(20.0, 1.0),
        );
      },
    );
  });

  group('RustImageCore FFI Bindings', () {
    test('loads native library when built and verifies all 7 RGBA operations', () {
      expect(
        RustImageCore.isAvailable,
        isTrue,
        reason:
            'snipsnap_core shared library should be built in native/snipsnap_core/target/release',
      );

      // 1. floodFillRgba (contiguous + global)
      // 4x1 strip: [white, black, white, white]
      final fillBuf = Uint8List.fromList([
        255,
        255,
        255,
        255,
        0,
        0,
        0,
        255,
        255,
        255,
        255,
        255,
        255,
        255,
        255,
        255,
      ]);
      final changed = RustImageCore.floodFillRgba(
        rgba: fillBuf,
        width: 4,
        height: 1,
        startX: 0,
        startY: 0,
        fillRgbaPacked: 0x112233FF,
        tolerancePercent: 0.0,
        opacity: 1.0,
        isGlobal: false,
      );
      expect(changed, isTrue);
      // Pixel 0 filled; pixel 2 blocked by black pixel 1.
      expect(fillBuf.sublist(0, 4), [0x11, 0x22, 0x33, 0xFF]);
      expect(fillBuf.sublist(8, 12), [255, 255, 255, 255]);

      final globalChanged = RustImageCore.floodFillRgba(
        rgba: fillBuf,
        width: 4,
        height: 1,
        startX: 2,
        startY: 0,
        fillRgbaPacked: 0x445566FF,
        tolerancePercent: 0.0,
        opacity: 1.0,
        isGlobal: true,
      );
      expect(globalChanged, isTrue);
      expect(fillBuf.sublist(8, 16), [
        0x44,
        0x55,
        0x66,
        0xFF,
        0x44,
        0x55,
        0x66,
        0xFF,
      ]);

      // 2. cropRgba (2x2 from 4x4)
      final grid = Uint8List(4 * 4 * 4);
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          final i = (y * 4 + x) * 4;
          grid[i] = x * 40;
          grid[i + 1] = y * 40;
          grid[i + 2] = 200;
          grid[i + 3] = 255;
        }
      }
      final cropped = RustImageCore.cropRgba(
        src: grid,
        srcWidth: 4,
        srcHeight: 4,
        cropX: 1,
        cropY: 2,
        cropWidth: 2,
        cropHeight: 2,
      );
      expect(cropped, isNotNull);
      expect(cropped!.length, 2 * 2 * 4);
      // First cropped pixel corresponds to (1, 2) => (40, 80, 200, 255)
      expect(cropped.sublist(0, 4), [40, 80, 200, 255]);

      // 3. eraseRectRgba
      final eraseBuf = Uint8List.fromList(grid);
      expect(
        RustImageCore.eraseRectRgba(
          rgba: eraseBuf,
          width: 4,
          height: 4,
          rectX: 1,
          rectY: 1,
          rectW: 2,
          rectH: 2,
        ),
        isTrue,
      );
      // (1, 1) zeroed; (0, 0) untouched
      expect(eraseBuf.sublist((1 * 4 + 1) * 4, (1 * 4 + 1) * 4 + 4), [
        0,
        0,
        0,
        0,
      ]);
      expect(eraseBuf.sublist(0, 4), [0, 0, 200, 255]);

      // 4. compositeRgba (opaque green over black at (1, 1))
      final dst = Uint8List.fromList([
        0,
        0,
        0,
        255,
        0,
        0,
        0,
        255,
        0,
        0,
        0,
        255,
        0,
        0,
        0,
        255,
      ]);
      final src = Uint8List.fromList([0, 200, 100, 255]);
      expect(
        RustImageCore.compositeRgba(
          dst: dst,
          dstWidth: 2,
          dstHeight: 2,
          src: src,
          srcWidth: 1,
          srcHeight: 1,
          dstX: 1,
          dstY: 1,
        ),
        isTrue,
      );
      expect(dst.sublist(12, 16), [0, 200, 100, 255]);
      expect(dst.sublist(0, 4), [0, 0, 0, 255]);

      // 5. resizeRgba (solid 2x2 blue -> 4x3 blue)
      final solidSrc = Uint8List.fromList([
        10,
        20,
        250,
        255,
        10,
        20,
        250,
        255,
        10,
        20,
        250,
        255,
        10,
        20,
        250,
        255,
      ]);
      final resized = RustImageCore.resizeRgba(
        src: solidSrc,
        srcWidth: 2,
        srcHeight: 2,
        dstWidth: 4,
        dstHeight: 3,
      );
      expect(resized, isNotNull);
      expect(resized!.length, 4 * 3 * 4);
      expect(resized.sublist(0, 4), [10, 20, 250, 255]);
      expect(resized.sublist(resized.length - 4), [10, 20, 250, 255]);

      // 6. pixelateRegionRgba
      final pixBuf = Uint8List(4 * 4 * 4);
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          final i = (y * 4 + x) * 4;
          pixBuf[i] = x < 2 ? 0 : 200;
          pixBuf[i + 3] = 255;
        }
      }
      expect(
        RustImageCore.pixelateRegionRgba(
          rgba: pixBuf,
          width: 4,
          height: 4,
          rectX: 1,
          rectY: 0,
          rectW: 2,
          rectH: 2,
          blockSize: 2,
        ),
        isTrue,
      );
      // Pixels (1,0) and (2,0) inside the 2x2 block average 0 and 200 -> ~100, while (3,0) stays 200.
      expect(pixBuf[(0 * 4 + 1) * 4], closeTo(100, 1));
      expect(pixBuf[(0 * 4 + 2) * 4], closeTo(100, 1));
      expect(pixBuf[(0 * 4 + 3) * 4], 200);

      // 7. boxBlurRegionRgba
      final blurBuf = Uint8List(8 * 8 * 4);
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          final i = (y * 8 + x) * 4;
          blurBuf[i] = x < 4 ? 0 : 240;
          blurBuf[i + 3] = 255;
        }
      }
      expect(
        RustImageCore.boxBlurRegionRgba(
          rgba: blurBuf,
          width: 8,
          height: 8,
          rectX: 2,
          rectY: 2,
          rectW: 4,
          rectH: 4,
          radius: 2,
        ),
        isTrue,
      );
      // Edge pixel inside blur rect (x=3, y=3) is no longer 0, and outside pixel (0, 0) stays 0.
      expect(blurBuf[(3 * 8 + 3) * 4], greaterThan(0));
      expect(blurBuf[(3 * 8 + 3) * 4], lessThan(240));
      expect(blurBuf[0], 0);
    });
  });

  group('Zoom-Invariant Tool Sizing & Chrome', () {
    late Directory tempDir;
    late String tallPngPath;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('snipsnap_zoom_tools_');
      tallPngPath = '${tempDir.path}/tall_800x9000.png';
      final tall = img.Image(width: 800, height: 9000);
      img.fill(tall, color: img.ColorRgba8(245, 245, 250, 255));
      File(tallPngPath).writeAsBytesSync(img.encodePng(tall, level: 1));
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('Annotation.withCanvasSpaceScalars compensates by viewScale', () {
      final projection = CanvasProjection(
        imageSize: const Size(1000, 9000),
        canvasSize: const Size(1200, 760),
      );
      final base = Annotation(
        id: 't1',
        tool: CanvasTool.pen,
        color: const Color(0xFFFF0000),
        strokeWidth: 1,
        fontSize: 1,
      );

      final zoomed = base.withCanvasSpaceScalars(
        projection,
        strokeWidth: 4.0,
        fontSize: 18.0,
        viewScale: projection.scale,
      );
      expect(zoomed.strokeWidth, closeTo(4.0, 0.01));
      expect(zoomed.fontSize, closeTo(18.0, 0.01));

      final unzoomed = base.withCanvasSpaceScalars(
        projection,
        strokeWidth: 4.0,
        fontSize: 18.0,
      );
      expect(unzoomed.strokeWidth, closeTo(4.0 * projection.scale, 0.01));
      expect(unzoomed.fontSize, closeTo(18.0 * projection.scale, 0.01));
    });

    test(
      'AnnotationRenderer scales heads, caps, selection bounds, and hit-tests cleanly when zoomed',
      () {
        final zoomedArrow = Annotation(
          id: 'a1',
          tool: CanvasTool.arrow,
          color: const Color(0xFF000000),
          strokeWidth: 4.0 / 12.0,
          startPoint: const Offset(100, 100),
          endPoint: const Offset(200, 100),
        );
        final head = AnnotationRenderer.arrowHead(zoomedArrow);
        expect(head.length, closeTo(16.0 / 12.0, 0.01));

        final zoomedRuler = Annotation(
          id: 'r1',
          tool: CanvasTool.ruler,
          color: const Color(0xFF000000),
          strokeWidth: 3.0 / 12.0,
          startPoint: const Offset(100, 100),
          endPoint: const Offset(200, 100),
        );
        expect(
          AnnotationRenderer.rulerCapHalf(zoomedRuler),
          closeTo(0.875, 0.01),
        );

        final box = Annotation(
          id: 's1',
          tool: CanvasTool.shape,
          color: const Color(0xFF000000),
          strokeWidth: 2.0 / 12.0,
          startPoint: const Offset(100, 100),
          endPoint: const Offset(110, 110),
        );
        final selRect = AnnotationRenderer.selectionRect(box, viewScale: 12.0);
        expect(selRect.width, closeTo(10.0 + 16.0 / 12.0, 0.01));

        final line = Annotation(
          id: 'l1',
          tool: CanvasTool.line,
          color: const Color(0xFF000000),
          strokeWidth: 2.0 / 12.0,
          startPoint: const Offset(100, 100),
          endPoint: const Offset(150, 100),
        );
        // 5 canvas units = 60 screen px at 12x -> miss at 12x, hit at 1x.
        expect(
          AnnotationRenderer.hitTest(
            line,
            const Offset(125, 105),
            viewScale: 12.0,
          ),
          isFalse,
        );
        expect(
          AnnotationRenderer.hitTest(
            line,
            const Offset(125, 105),
            viewScale: 1.0,
          ),
          isTrue,
        );
        expect(
          AnnotationRenderer.hitTest(
            line,
            const Offset(125, 100.5),
            viewScale: 12.0,
          ),
          isTrue,
        );
      },
    );

    testWidgets(
      'drawing Arrow, StepMarker, and Pen on auto-zoomed tall image keeps screen-constant size and keeps Delete chip outside InteractiveViewer',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1200, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        Future<({List<Annotation> added, Annotation? selected})> runDraw({
          required CanvasTool tool,
          required Future<void> Function() action,
        }) async {
          final added = <Annotation>[];
          Annotation? selected;
          var annotations = <Annotation>[];
          final repaintKey = GlobalKey();
          late StateSetter hostSetState;

          await tester.runAsync(() async {
            await tester.pumpWidget(
              SnipThemeScope(
                theme: SnipTheme.forMode(SnipThemeMode.dark),
                child: MaterialApp(
                  home: Scaffold(
                    body: StatefulBuilder(
                      builder: (context, setState) {
                        hostSetState = setState;
                        return SizedBox(
                          width: 1200,
                          height: 800,
                          child: EditorCanvas(
                            imagePath: tallPngPath,
                            annotations: annotations,
                            activeTool: tool,
                            activeColor: const Color(0xFFEF4444),
                            strokeWidth: 4.0,
                            fontSize: 18.0,
                            isFilled: false,
                            stepCounter: 1,
                            onAnnotationAdded: (ann) {
                              added.add(ann);
                              hostSetState(() {
                                annotations = [...annotations, ann];
                              });
                            },
                            onSelectAnnotation: (ann) => selected = ann,
                            onStepCounterIncremented: (_) {},
                            repaintBoundaryKey: repaintKey,
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            );
            await settleBaseImage(tester);
          });
          await tester.pumpAndSettle();

          expect(_scale(tester), greaterThan(4.0));
          await action();
          await tester.pumpAndSettle();
          return (added: added, selected: selected);
        }

        // 1. Arrow: strokeWidth matches 4.0px screen size instead of 4 * 11.84 = 47px,
        // sliders receive ~4.0 back, and Delete chip sits outside InteractiveViewer.
        final arrowRes = await runDraw(
          tool: CanvasTool.arrow,
          action: () async {
            final gesture = await tester.startGesture(
              const Offset(500, 300),
              kind: PointerDeviceKind.mouse,
            );
            await tester.pump(const Duration(milliseconds: 16));
            await gesture.moveTo(const Offset(700, 380));
            await tester.pump(const Duration(milliseconds: 16));
            await gesture.up();
            await tester.pumpAndSettle();

            expect(find.byIcon(Icons.close_rounded), findsOneWidget);
            expect(
              find.descendant(
                of: find.byType(InteractiveViewer),
                matching: find.byIcon(Icons.close_rounded),
              ),
              findsNothing,
              reason:
                  'Delete chip must live in viewport space outside InteractiveViewer',
            );
          },
        );
        expect(arrowRes.added, hasLength(1));
        expect(arrowRes.added.single.strokeWidth, closeTo(4.0, 0.25));
        expect(arrowRes.selected, isNotNull);
        expect(arrowRes.selected!.strokeWidth, closeTo(4.0, 0.25));

        // 2. Step Marker: fontSize stays ~18px instead of blowing up to ~213px.
        final stepRes = await runDraw(
          tool: CanvasTool.stepMarker,
          action: () async {
            await tester.tapAt(const Offset(600, 400));
            await tester.pumpAndSettle();
          },
        );
        expect(stepRes.added, hasLength(1));
        expect(stepRes.added.single.fontSize, closeTo(18.0, 0.5));

        // 3. Pen: 30 screen-px drag samples densely (>= 4 points) and stays ~4.0px wide.
        final penRes = await runDraw(
          tool: CanvasTool.pen,
          action: () async {
            final gesture = await tester.startGesture(
              const Offset(580, 350),
              kind: PointerDeviceKind.mouse,
            );
            await tester.pump(const Duration(milliseconds: 16));
            for (var i = 1; i <= 6; i++) {
              await gesture.moveTo(Offset(580 + i * 5.0, 350));
              await tester.pump(const Duration(milliseconds: 16));
            }
            await gesture.up();
            await tester.pumpAndSettle();
          },
        );
        expect(penRes.added, hasLength(1));
        expect(penRes.added.single.strokeWidth, closeTo(4.0, 0.25));
        expect(penRes.added.single.points.length, greaterThanOrEqualTo(4));
      },
    );
  });
}
