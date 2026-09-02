// Regression: ISSUE-002 — every tool anchored its origin one pointer event
// past the press: the canvas GestureDetector used the default
// DragStartBehavior.start, so `onPanStart` reported where the recognizer won,
// not where the button went down. A marquee, shape or crop box therefore
// started wherever the first move landed — 10-45px late on a fast start.
// Found by /qa on 2026-09-02
// Report: .gstack/qa-reports/qa-report-snipsnap-2026-09-02.md
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:snipsnap/utils/constants.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/editor_canvas.dart';

import 'support/base_image_settle.dart';

/// A drag that covers the whole distance in [steps] moves — a fast hand. The
/// existing gesture tests step every 3px, which hides an origin that trails
/// the press by a single event; a two-step drag makes that trail half the
/// distance and impossible to miss.
Future<void> _fastDrag(
  WidgetTester tester,
  Offset from,
  Offset to, {
  int steps = 2,
}) async {
  final gesture = await tester.startGesture(
    from,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump(const Duration(milliseconds: 16));
  for (var i = 1; i <= steps; i++) {
    await gesture.moveTo(Offset.lerp(from, to, i / steps)!);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

/// The crop tool is the one drag-driven rectangle whose geometry leaves the
/// canvas through a public callback, so it stands in for the marquee, the
/// shapes and the OCR region, which all take their origin from the same
/// `onPanStart` position.
Future<({RenderBox box, List<Rect> applied})> _pumpCrop(
  WidgetTester tester,
  String path,
) async {
  final applied = <Rect>[];
  final key = GlobalKey();
  await tester.runAsync(() async {
    await tester.pumpWidget(
      SnipThemeScope(
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
      ),
    );
    await settleBaseImage(tester);
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
    dir = Directory.systemTemp.createTempSync('snipsnap_drag_origin');
    path = '${dir.path}/capture.png';
    final image = img.Image(width: 1200, height: 900);
    img.fill(image, color: img.ColorRgb8(240, 240, 240));
    File(path).writeAsBytesSync(img.encodePng(image));
  });

  tearDown(() => dir.deleteSync(recursive: true));

  testWidgets('a rectangle dragged out fast still starts under the press', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final h = await _pumpCrop(tester, path);
    Offset at(double x, double y) => h.box.localToGlobal(Offset(x, y));

    // Press at (200,200), reach (400,300) in two moves. With the origin taken
    // from the first move this box began at (300,250) and came out 100x50.
    await _fastDrag(tester, at(200, 200), at(400, 300));

    await tester.tap(find.textContaining('Apply'));
    await tester.pumpAndSettle();

    expect(h.applied, hasLength(1));
    final rect = h.applied.single;
    expect(
      rect.left,
      closeTo(200, 4),
      reason: 'the box must be anchored where the button went down',
    );
    expect(rect.top, closeTo(200, 4));
    expect(
      rect.width,
      closeTo(200, 4),
      reason: 'and span the whole drag, not the part after the first event',
    );
    expect(rect.height, closeTo(100, 4));
  });

  testWidgets('a slow drag is unchanged by the start behaviour', (
    tester,
  ) async {
    // The guard for the fix itself: reporting the press position must not
    // shift a careful drag, which never had a visible gap to begin with.
    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final h = await _pumpCrop(tester, path);
    Offset at(double x, double y) => h.box.localToGlobal(Offset(x, y));

    await _fastDrag(tester, at(150, 150), at(450, 350), steps: 100);

    await tester.tap(find.textContaining('Apply'));
    await tester.pumpAndSettle();

    final rect = h.applied.single;
    expect(rect.left, closeTo(150, 4));
    expect(rect.top, closeTo(150, 4));
    expect(rect.width, closeTo(300, 4));
    expect(rect.height, closeTo(200, 4));
  });
}
