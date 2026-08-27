import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:snipsnap/services/render_service.dart';
import 'package:snipsnap/utils/constants.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/editor_canvas.dart';

/// Pumps an [EditorCanvas] on the crop tool over a real 1600x900 PNG and
/// returns the repaint-boundary box the crop rect is measured against.
///
/// The bitmap decode runs through `compute` and `dart:io`, neither of which
/// advances under a plain `pump`, so the pump is bracketed by a `runAsync`
/// delay. Without it `_baseImage` stays null, the image rect degenerates to
/// the whole viewport, and the assertions below would be measuring nothing.
Future<({RenderBox box, Rect imageRect})> _pumpCropCanvas(
  WidgetTester tester, {
  required GlobalKey repaintKey,
  required String imagePath,
  required ValueChanged<Rect> onApplyCrop,
}) async {
  final tree = SnipThemeScope(
    theme: SnipTheme.forMode(SnipThemeMode.dark),
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 900,
          height: 700,
          child: EditorCanvas(
            imagePath: imagePath,
            annotations: const [],
            activeTool: CanvasTool.crop,
            activeColor: const Color(0xFFFF0000),
            strokeWidth: 4,
            fontSize: 16,
            isFilled: false,
            stepCounter: 1,
            onAnnotationAdded: (_) {},
            onStepCounterIncremented: (_) {},
            onApplyCrop: onApplyCrop,
            repaintBoundaryKey: repaintKey,
          ),
        ),
      ),
    ),
  );
  // The bitmap load is kicked off from `initState`, so the *first* pump has to
  // happen inside `runAsync` — started in the fake-async zone, its `compute`
  // and `dart:io` continuations never run and `_baseImage` stays null forever.
  await tester.runAsync(() async {
    await tester.pumpWidget(tree);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pump();
  });
  await tester.pumpAndSettle();

  final box = repaintKey.currentContext!.findRenderObject() as RenderBox;
  return (
    box: box,
    imageRect: RenderService.imageRectInCanvas(
      imageSize: const Size(1600, 900),
      canvasSize: box.size,
    ),
  );
}

/// Drags in small steps with a mouse pointer.
///
/// Small steps because one big jump is consumed as the pan's slop, leaving
/// `_gestureStartPos` at the far end and the delta at zero. A mouse rather than
/// a finger because this is a desktop app, and because touch slop would
/// otherwise displace the start of the drawn box by 36 logical pixels.
Future<void> _dragBy(WidgetTester tester, Offset from, Offset to) async {
  final gesture = await tester.startGesture(
    from,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump(const Duration(milliseconds: 16));
  // Nudge past the precise-pointer pan slop first, so the recognised start of
  // the drag is within a couple of pixels of the press.
  await gesture.moveTo(from + const Offset(2, 2));
  await tester.pump(const Duration(milliseconds: 16));
  for (var i = 1; i <= 20; i++) {
    await gesture.moveTo(Offset.lerp(from, to, i / 20)!);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late String imagePath;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('snipsnap_crop');
    imagePath = '${dir.path}/capture.png';
    final image = img.Image(width: 1600, height: 900);
    img.fill(image, color: img.ColorRgb8(200, 30, 30));
    File(imagePath).writeAsBytesSync(img.encodePng(image));
  });

  tearDown(() => dir.deleteSync(recursive: true));

  testWidgets(
    'the first drag draws a crop region instead of sliding the default box',
    (tester) async {
      // The regression: the crop tool pre-fills its box with the whole image, so
      // every press that lands on the picture also lands inside the box. Read as
      // a body drag, the first gesture moved the image-sized box off to one side
      // and applying it kept only the sliver still over the picture.
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final repaintKey = GlobalKey();
      Rect? applied;
      final pumped = await _pumpCropCanvas(
        tester,
        repaintKey: repaintKey,
        imagePath: imagePath,
        onApplyCrop: (rect) => applied = rect,
      );
      final imageRect = pumped.imageRect;
      expect(
        imageRect.height,
        lessThan(pumped.box.size.height),
        reason:
            'the 16:9 capture must letterbox inside the taller canvas, '
            'otherwise the bitmap never decoded and this test proves nothing',
      );

      Offset atFraction(double fx, double fy) => pumped.box.localToGlobal(
        Offset(
          imageRect.left + imageRect.width * fx,
          imageRect.top + imageRect.height * fy,
        ),
      );

      await _dragBy(tester, atFraction(0.25, 0.25), atFraction(0.75, 0.75));
      await tester.tap(find.text('Apply Crop'));
      await tester.pumpAndSettle();

      expect(applied, isNotNull);
      final expected = Rect.fromLTRB(
        imageRect.left + imageRect.width * 0.25,
        imageRect.top + imageRect.height * 0.25,
        imageRect.left + imageRect.width * 0.75,
        imageRect.top + imageRect.height * 0.75,
      );
      expect(applied!.left, closeTo(expected.left, 3.0));
      expect(applied!.top, closeTo(expected.top, 3.0));
      expect(applied!.right, closeTo(expected.right, 3.0));
      expect(applied!.bottom, closeTo(expected.bottom, 3.0));
    },
  );

  testWidgets('a box the user drew can still be moved by dragging its body', (
    tester,
  ) async {
    // The fix must not cost the ordinary reposition: only the untouched
    // default redirects an interior drag into drawing a new region.
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final repaintKey = GlobalKey();
    Rect? applied;
    final pumped = await _pumpCropCanvas(
      tester,
      repaintKey: repaintKey,
      imagePath: imagePath,
      onApplyCrop: (rect) => applied = rect,
    );
    final imageRect = pumped.imageRect;

    Offset atFraction(double fx, double fy) => pumped.box.localToGlobal(
      Offset(
        imageRect.left + imageRect.width * fx,
        imageRect.top + imageRect.height * fy,
      ),
    );

    // Draw a box over the left half, then drag its middle to the right.
    await _dragBy(tester, atFraction(0.10, 0.20), atFraction(0.50, 0.80));
    final shift = imageRect.width * 0.20;
    await _dragBy(tester, atFraction(0.30, 0.50), atFraction(0.50, 0.50));

    await tester.tap(find.text('Apply Crop'));
    await tester.pumpAndSettle();

    expect(applied, isNotNull);
    expect(
      applied!.left,
      closeTo(imageRect.left + imageRect.width * 0.10 + shift, 4.0),
    );
    expect(
      applied!.width,
      closeTo(imageRect.width * 0.40, 4.0),
      reason: 'a move must not resize the box',
    );
  });
}
