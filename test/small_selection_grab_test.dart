import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:snipsnap/utils/constants.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/editor_canvas.dart';

/// Drives the crop rectangle, which is powered by the same `_hitTestCropRect`
/// the floating selection uses — and is the only one of the two whose geometry
/// leaves the canvas through a public callback, so it can be asserted on
/// without reaching into private state or waiting on bitmap I/O.
Future<void> _drag(WidgetTester tester, Offset from, Offset to) async {
  final gesture = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
  await tester.pump(const Duration(milliseconds: 16));
  final steps = ((to - from).distance ~/ 3) + 8;
  for (var i = 1; i <= steps; i++) {
    await gesture.moveTo(Offset.lerp(from, to, i / steps)!);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

Future<({RenderBox box, List<Rect> applied})> _pumpCrop(
  WidgetTester tester,
  String path,
) async {
  final applied = <Rect>[];
  final key = GlobalKey();
  await tester.runAsync(() async {
    await tester.pumpWidget(SnipThemeScope(
      theme: SnipTheme.forMode(SnipThemeMode.dark),
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 700,
            height: 600,
            child: EditorCanvas(
              imagePath: path,
              annotations: const [],
              activeTool: CanvasTool.crop,
              activeColor: const Color(0xFF000000),
              strokeWidth: 4,
              fontSize: 16,
              isFilled: false,
              stepCounter: 1,
              onAnnotationAdded: (_) {},
              onStepCounterIncremented: (_) {},
              onApplyCrop: applied.add,
              repaintBoundaryKey: key,
            ),
          ),
        ),
      ),
    ));
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await tester.pump();
  });
  await tester.pumpAndSettle();
  return (
    box: key.currentContext!.findRenderObject() as RenderBox,
    applied: applied,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('snipsnap_small_grab');
    path = '${dir.path}/capture.png';
    final image = img.Image(width: 1200, height: 900);
    img.fill(image, color: img.ColorRgb8(240, 240, 240));
    File(path).writeAsBytesSync(img.encodePng(image));
  });

  tearDown(() => dir.deleteSync(recursive: true));

  testWidgets('a word-sized rect can be grabbed by its middle and moved',
      (tester) async {
    // The report: marquee something as small as a short word and the whole
    // rect was grab band — 18px on each side leaves no middle in a 46x30 box —
    // so the one thing you could not do with it was drag it somewhere.
    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final h = await _pumpCrop(tester, path);
    Offset at(double x, double y) => h.box.localToGlobal(Offset(x, y));

    // A 46x30 box, the size the fixed bands used to swallow whole.
    await _drag(tester, at(200, 200), at(246, 230));
    // Grab its middle and carry it clear.
    await _drag(tester, at(223, 215), at(383, 335));

    await tester.tap(find.textContaining('Apply'));
    await tester.pumpAndSettle();

    expect(h.applied, hasLength(1));
    final rect = h.applied.single;
    expect(rect.width, closeTo(46, 6),
        reason: 'the box moved, not resized — an edge grab would have '
            'stretched it, and a missed grab would have drawn a new one');
    expect(rect.height, closeTo(30, 6));
    expect(rect.center.dx, greaterThan(300),
        reason: 'and it must have travelled with the pointer');
    expect(rect.center.dy, greaterThan(280));
  });

  testWidgets('a comfortable rect keeps full-size edge handles', (tester) async {
    // The bands only shrink where they have to: a normal selection must still
    // offer a generous 18px edge to grab, or the fix would have traded one
    // problem for a fiddlier one.
    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final h = await _pumpCrop(tester, path);
    Offset at(double x, double y) => h.box.localToGlobal(Offset(x, y));

    // 300x200 — a quarter of each side is well over 18, so the cap does not
    // bind and the bands stay at their full size.
    await _drag(tester, at(150, 150), at(450, 350));
    // 14px inside the right edge: still edge, so this resizes rather than moves.
    await _drag(tester, at(436, 250), at(536, 250));

    await tester.tap(find.textContaining('Apply'));
    await tester.pumpAndSettle();

    expect(h.applied, hasLength(1));
    final rect = h.applied.single;
    expect(rect.width, greaterThan(360),
        reason: 'grabbing near the edge must still resize a large rect');
    expect(rect.height, closeTo(200, 8),
        reason: 'and only along the edge that was grabbed');
  });
}
