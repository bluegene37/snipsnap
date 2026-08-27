import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:snipsnap/models/annotation.dart';
import 'package:snipsnap/utils/constants.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/editor_canvas.dart';

Matrix4 _transform(WidgetTester tester) => tester
    .widget<InteractiveViewer>(find.byType(InteractiveViewer))
    .transformationController!
    .value;

/// Pumps the canvas on [tool] and returns the annotations it emits.
Future<List<Annotation>> _pumpCanvas(
  WidgetTester tester, {
  required String imagePath,
  required CanvasTool tool,
}) async {
  final added = <Annotation>[];
  final key = GlobalKey();
  await tester.runAsync(() async {
    await tester.pumpWidget(
      SnipThemeScope(
        theme: SnipTheme.forMode(SnipThemeMode.dark),
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 500,
              child: EditorCanvas(
                imagePath: imagePath,
                annotations: const [],
                activeTool: tool,
                activeColor: const Color(0xFF000000),
                strokeWidth: 4,
                fontSize: 16,
                isFilled: false,
                stepCounter: 1,
                onAnnotationAdded: added.add,
                onStepCounterIncremented: (_) {},
                repaintBoundaryKey: key,
              ),
            ),
          ),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await tester.pump();
  });
  await tester.pumpAndSettle();
  return added;
}

/// A two-finger trackpad swipe: the gesture macOS sends to scroll around.
Future<void> _twoFingerPan(
  WidgetTester tester,
  Offset at,
  Offset totalPan,
) async {
  final pointer = TestPointer(1, PointerDeviceKind.trackpad);
  await tester.sendEventToBinding(pointer.panZoomStart(at));
  await tester.pump();
  for (var i = 1; i <= 10; i++) {
    await tester.sendEventToBinding(
      pointer.panZoomUpdate(at, pan: totalPan * (i / 10)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.sendEventToBinding(pointer.panZoomEnd());
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late String imagePath;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('snipsnap_trackpad');
    imagePath = '${dir.path}/capture.png';
    final image = img.Image(width: 1600, height: 900);
    img.fill(image, color: img.ColorRgb8(180, 40, 40));
    File(imagePath).writeAsBytesSync(img.encodePng(image));
  });

  tearDown(() => dir.deleteSync(recursive: true));

  // Every tool that commits something on a drag. `DragGestureRecognizer`
  // accepts a trackpad `PointerPanZoom` sequence as a drag, so before the
  // device filter a two-finger swipe to scroll left a stray mark behind with
  // whichever of these was selected.
  for (final tool in const [
    CanvasTool.pen,
    CanvasTool.line,
    CanvasTool.arrow,
    CanvasTool.shape,
    CanvasTool.highlight,
    CanvasTool.blur,
    CanvasTool.ruler,
  ]) {
    testWidgets('a two-finger pan draws nothing with ${tool.name}', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(800, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final added = await _pumpCanvas(tester, imagePath: imagePath, tool: tool);
      await _twoFingerPan(
        tester,
        const Offset(300, 250),
        const Offset(0, -140),
      );

      expect(
        added,
        isEmpty,
        reason: 'scrolling around the capture must not mark it up',
      );
    });
  }

  testWidgets('a two-finger pan still moves the view', (tester) async {
    // The filter must not cost the gesture it was added to protect.
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpCanvas(tester, imagePath: imagePath, tool: CanvasTool.pen);

    // Zoom in first, or there is nowhere to pan to.
    final pointer = TestPointer(2, PointerDeviceKind.trackpad);
    await tester.sendEventToBinding(
      pointer.panZoomStart(const Offset(300, 250)),
    );
    await tester.pump();
    await tester.sendEventToBinding(
      pointer.panZoomUpdate(const Offset(300, 250), scale: 2.5),
    );
    await tester.pumpAndSettle();
    await tester.sendEventToBinding(pointer.panZoomEnd());
    await tester.pumpAndSettle();
    expect(
      _transform(tester).getMaxScaleOnAxis(),
      greaterThan(1.5),
      reason: 'pinch must zoom',
    );

    final before = _transform(tester).storage[13];
    await _twoFingerPan(tester, const Offset(300, 250), const Offset(0, -120));
    expect(
      _transform(tester).storage[13],
      lessThan(before),
      reason: 'two-finger swipe must still scroll the view',
    );
  });

  testWidgets('a click-drag on the same trackpad still draws', (tester) async {
    // A trackpad *click* arrives as PointerDeviceKind.mouse, which the filter
    // keeps — otherwise trackpad users could not draw at all.
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final added = await _pumpCanvas(
      tester,
      imagePath: imagePath,
      tool: CanvasTool.line,
    );

    const from = Offset(150, 150);
    const to = Offset(400, 320);
    final gesture = await tester.startGesture(
      from,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 16));
    for (var i = 1; i <= 10; i++) {
      await gesture.moveTo(Offset.lerp(from, to, i / 10)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(added, hasLength(1), reason: 'drawing must still work');
  });
}
