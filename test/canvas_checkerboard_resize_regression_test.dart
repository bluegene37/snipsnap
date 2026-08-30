// Regression: ISSUE-003 — the transparency checkerboard under the capture was
// positioned from `_imageRect`, which measures the RepaintBoundary's render
// box and therefore reports the *previous* layout. On the frame a viewport
// resize landed — hiding the gallery strip with Cmd+H, resizing the window,
// collapsing the properties panel — the checkerboard kept the old geometry
// while RawImage re-fitted to the new one, and nothing scheduled a second
// build to correct it. It slid out from under the screenshot and sat beside it
// as a transparent band until the user clicked Fit.
// Found by /qa on 2026-08-30
// Report: .gstack/qa-reports/qa-report-snipsnap-2026-08-30.md

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:snipsnap/services/render_service.dart';
import 'package:snipsnap/utils/constants.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/editor_canvas.dart';

const Size _imageSize = Size(1600, 900);

/// The checkerboard's painter is private, so match it by name rather than
/// widening the library's API just for a test.
Finder _checkerboard() => find.byWidgetPredicate(
  (w) =>
      w is CustomPaint &&
      w.painter.runtimeType.toString() == '_SteadyCheckerboardPainter',
);

/// Where the checkerboard *should* sit: the fitted image rect for the canvas
/// as it is laid out right now.
Rect _expectedRect(WidgetTester tester, GlobalKey repaintKey) {
  final canvas = tester.getRect(find.byKey(repaintKey));
  return RenderService.imageRectInCanvas(
    imageSize: _imageSize,
    canvasSize: canvas.size,
  ).shift(canvas.topLeft);
}

Future<void> _pumpCanvas(
  WidgetTester tester, {
  required String imagePath,
  required GlobalKey repaintKey,
  required double height,
  bool settle = false,
}) async {
  Widget tree() => SnipThemeScope(
    theme: SnipTheme.forMode(SnipThemeMode.dark),
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 900,
          height: height,
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
            repaintBoundaryKey: repaintKey,
          ),
        ),
      ),
    ),
  );

  if (settle) {
    await tester.pumpWidget(tree());
    await tester.pumpAndSettle();
    return;
  }

  // The bitmap decodes off the platform thread, so the first pump alone paints
  // nothing; runAsync lets the decode actually land.
  await tester.runAsync(() async {
    await tester.pumpWidget(tree());
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await tester.pump();
  });
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late String imagePath;
  late GlobalKey repaintKey;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('snipsnap_checkerboard');
    imagePath = '${dir.path}/capture.png';
    final image = img.Image(
      width: _imageSize.width.toInt(),
      height: _imageSize.height.toInt(),
    );
    img.fill(image, color: img.ColorRgb8(180, 40, 40));
    File(imagePath).writeAsBytesSync(img.encodePng(image));
    repaintKey = GlobalKey();
  });

  tearDown(() => dir.deleteSync(recursive: true));

  testWidgets('the checkerboard sits under the capture when first laid out', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _pumpCanvas(
      tester,
      imagePath: imagePath,
      repaintKey: repaintKey,
      height: 700,
    );

    final actual = tester.getRect(_checkerboard());
    final expected = _expectedRect(tester, repaintKey);
    expect(actual.left, closeTo(expected.left, 0.5));
    expect(actual.top, closeTo(expected.top, 0.5));
    expect(actual.width, closeTo(expected.width, 0.5));
    expect(actual.height, closeTo(expected.height, 0.5));
  });

  testWidgets('the checkerboard follows the capture when the viewport grows', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _pumpCanvas(
      tester,
      imagePath: imagePath,
      repaintKey: repaintKey,
      height: 500,
    );
    final before = tester.getRect(_checkerboard());

    // Same EditorCanvas element, taller box — exactly what hiding the gallery
    // strip does to the canvas.
    await _pumpCanvas(
      tester,
      imagePath: imagePath,
      repaintKey: repaintKey,
      height: 860,
      settle: true,
    );

    final actual = tester.getRect(_checkerboard());
    final expected = _expectedRect(tester, repaintKey);

    expect(actual.height, greaterThan(before.height),
        reason: 'the fitted capture grew, so its backdrop must grow with it');
    // The bug: `actual` stayed at `before`, i.e. the pre-resize geometry.
    expect(actual.left, closeTo(expected.left, 0.5));
    expect(actual.top, closeTo(expected.top, 0.5));
    expect(actual.width, closeTo(expected.width, 0.5));
    expect(actual.height, closeTo(expected.height, 0.5));
  });

  testWidgets('the checkerboard follows the capture when the viewport shrinks',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _pumpCanvas(
      tester,
      imagePath: imagePath,
      repaintKey: repaintKey,
      height: 860,
    );

    await _pumpCanvas(
      tester,
      imagePath: imagePath,
      repaintKey: repaintKey,
      height: 500,
      settle: true,
    );

    final actual = tester.getRect(_checkerboard());
    final expected = _expectedRect(tester, repaintKey);
    expect(actual.left, closeTo(expected.left, 0.5));
    expect(actual.top, closeTo(expected.top, 0.5));
    expect(actual.width, closeTo(expected.width, 0.5));
    expect(actual.height, closeTo(expected.height, 0.5));
  });
}
