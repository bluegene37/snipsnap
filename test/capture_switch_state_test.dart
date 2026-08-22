import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:snipsnap/utils/constants.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/editor_canvas.dart';

/// Builds the canvas for [imagePath]. Kept as a builder so a test can re-pump
/// the same widget position with a different capture, which is what a gallery
/// selection does.
Widget _canvas({
  required String imagePath,
  required GlobalKey repaintKey,
  required CanvasTool tool,
}) {
  return SnipThemeScope(
    theme: SnipTheme.forMode(SnipThemeMode.dark),
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 500,
          height: 460,
          child: EditorCanvas(
            imagePath: imagePath,
            annotations: const [],
            activeTool: tool,
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
}

/// Pumps inside `runAsync` so the bitmap decode — `compute` plus `dart:io`,
/// neither of which advances in the fake-async zone — actually completes.
Future<void> _pumpLoaded(WidgetTester tester, Widget tree) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(tree);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await tester.pump();
  });
  await tester.pumpAndSettle();
}

Future<void> _drag(WidgetTester tester, Offset from, Offset to) async {
  await tester.runAsync(() async {
    final gesture = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveTo(from + const Offset(2, 2));
    await tester.pump(const Duration(milliseconds: 16));
    for (var i = 1; i <= 12; i++) {
      await gesture.moveTo(Offset.lerp(from, to, i / 12)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await tester.pump();
  });
  await tester.pumpAndSettle();
}

/// Number of pixels in [path] whose red channel dominates — the marker colour
/// capture A is filled with.
int _redPixelCount(String path) {
  final decoded = img.decodeImage(File(path).readAsBytesSync())!;
  var count = 0;
  for (var y = 0; y < decoded.height; y++) {
    for (var x = 0; x < decoded.width; x++) {
      final p = decoded.getPixel(x, y);
      if (p.a > 200 && p.r > 180 && p.g < 80 && p.b < 80) count++;
    }
  }
  return count;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late String pathA;
  late String pathB;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('snipsnap_switch');
    pathA = '${dir.path}/a.png';
    pathB = '${dir.path}/b.png';
    final a = img.Image(width: 400, height: 300);
    img.fill(a, color: img.ColorRgb8(220, 30, 30));
    File(pathA).writeAsBytesSync(img.encodePng(a));
    // Portrait, and a different aspect ratio from A on purpose: a crop box
    // carried over from A then lands outside B's image rect, which is what the
    // second test detects.
    final b = img.Image(width: 200, height: 400);
    img.fill(b, color: img.ColorRgb8(30, 60, 220));
    File(pathB).writeAsBytesSync(img.encodePng(b));
  });

  tearDown(() => dir.deleteSync(recursive: true));

  testWidgets('a floating cut is never pasted into the capture switched to',
      (tester) async {
    // The regression: cut-and-move erases the region from the capture's file
    // immediately and holds the pixels in memory. Only a *tool* change cleared
    // that state, so switching captures carried the live cut across — and the
    // next commit stamped one capture's pixels into the other capture's file
    // while the original kept the hole.
    await tester.binding.setSurfaceSize(const Size(700, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final repaintKey = GlobalKey();
    await _pumpLoaded(
      tester,
      _canvas(imagePath: pathA, repaintKey: repaintKey, tool: CanvasTool.select),
    );

    final box = repaintKey.currentContext!.findRenderObject() as RenderBox;
    Offset at(double dx, double dy) => box.localToGlobal(Offset(dx, dy));

    // Marquee a region, then drag from inside it — that is what extracts the
    // pixels out of capture A's file and leaves a floating selection.
    await _drag(tester, at(120, 120), at(240, 220));
    await _drag(tester, at(180, 170), at(210, 190));

    final redInAAfterCut = _redPixelCount(pathA);
    expect(redInAAfterCut, lessThan(400 * 300),
        reason: 'the cut must actually have removed pixels from capture A, '
            'otherwise the rest of this test proves nothing');
    expect(_redPixelCount(pathB), 0, reason: 'capture B starts with no red');

    // Switch captures with the select tool still active...
    await _pumpLoaded(
      tester,
      _canvas(imagePath: pathB, repaintKey: repaintKey, tool: CanvasTool.select),
    );
    // ...then change tools, which is what used to flush the still-live cut —
    // into whichever capture happened to be on screen by then.
    await _pumpLoaded(
      tester,
      _canvas(imagePath: pathB, repaintKey: repaintKey, tool: CanvasTool.pen),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    await tester.pumpAndSettle();

    expect(_redPixelCount(pathB), 0,
        reason: "capture A's cut pixels must never be written into capture B");
    expect(_redPixelCount(pathA), greaterThan(redInAAfterCut),
        reason: 'switching away must put the floating cut back into the '
            'capture it came from, not strand it');
  });

  testWidgets('the crop box does not carry over to the next capture', (tester) async {
    // A crop box drawn on one capture stayed put across a switch, so applying
    // it cropped the new capture through the previous one's geometry.
    await tester.binding.setSurfaceSize(const Size(700, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final repaintKey = GlobalKey();
    await _pumpLoaded(
      tester,
      _canvas(imagePath: pathA, repaintKey: repaintKey, tool: CanvasTool.crop),
    );

    final box = repaintKey.currentContext!.findRenderObject() as RenderBox;
    Offset at(double dx, double dy) => box.localToGlobal(Offset(dx, dy));

    await _drag(tester, at(100, 120), at(200, 200));
    expect(find.textContaining('Apply'), findsOneWidget,
        reason: 'the drawn box must be live before the switch');

    await _pumpLoaded(
      tester,
      _canvas(imagePath: pathB, repaintKey: repaintKey, tool: CanvasTool.crop),
    );

    // B is portrait where A is landscape, so the rectangle drawn over A falls
    // outside B's image rect and the bar would read "Apply Expansion". The
    // fresh default box is the image itself, so it reads "Apply Crop".
    expect(find.text('Apply Crop'), findsOneWidget,
        reason: "an 'Apply Expansion' bar here means A's crop box survived the "
            'switch and is now hanging off the edge of B');
  });
}
