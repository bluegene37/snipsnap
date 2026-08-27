import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:snipsnap/models/annotation.dart';
import 'package:snipsnap/utils/constants.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/editor_canvas.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a drag notifies the parent once, on release', (tester) async {
    // Every pointer move used to go out to the parent, whose setState rebuilt
    // the header bar, both sidebars and the whole properties panel for a
    // change only the canvas painter cares about — ~92ms a frame with a few
    // captures in the tray, against ~12ms once the gesture stays local.
    //
    // Counting the callbacks is the durable form of that: a timing assertion
    // would be flaky, but "one update per gesture, not one per frame" is
    // exactly the property that made it fast and cannot drift silently.
    final dir = Directory.systemTemp.createTempSync('snipsnap_drag_scope');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/capture.png';
    final image = img.Image(width: 1200, height: 900);
    img.fill(image, color: img.ColorRgb8(240, 240, 240));
    File(path).writeAsBytesSync(img.encodePng(image));

    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var live = <Annotation>[
      Annotation(
        id: 'a1',
        tool: CanvasTool.shape,
        color: const Color(0xFF000000),
        strokeWidth: 6,
        fill: true,
        shapeKind: ShapeKind.rectangle,
        startPoint: const Offset(300, 300),
        endPoint: const Offset(700, 600),
      ),
    ];
    var liveUpdates = 0;
    var committedUpdates = 0;
    final key = GlobalKey();

    await tester.runAsync(() async {
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (ctx, setState) {
            return SnipThemeScope(
              theme: SnipTheme.forMode(SnipThemeMode.dark),
              child: MaterialApp(
                home: Scaffold(
                  body: SizedBox(
                    width: 700,
                    height: 600,
                    child: EditorCanvas(
                      imagePath: path,
                      annotations: live,
                      activeTool: CanvasTool.select,
                      activeColor: const Color(0xFF000000),
                      strokeWidth: 6,
                      fontSize: 16,
                      isFilled: true,
                      stepCounter: 1,
                      onAnnotationAdded: (_) {},
                      onStepCounterIncremented: (_) {},
                      onAnnotationsUpdated: (l) => setState(() {
                        committedUpdates++;
                        live = l;
                      }),
                      onAnnotationsLiveUpdated: (l) => setState(() {
                        liveUpdates++;
                        live = l;
                      }),
                      repaintBoundaryKey: key,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await tester.pump();
    });
    await tester.pumpAndSettle();

    final box = key.currentContext!.findRenderObject() as RenderBox;
    final from = box.localToGlobal(const Offset(290, 260));
    final to = box.localToGlobal(const Offset(430, 380));

    await tester.tapAt(from, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    liveUpdates = 0;
    committedUpdates = 0;

    final gesture = await tester.startGesture(
      from,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 16));
    for (var i = 1; i <= 40; i++) {
      await gesture.moveTo(Offset.lerp(from, to, i / 40)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    final duringDrag = liveUpdates;
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      duringDrag,
      0,
      reason:
          'the parent must hear nothing while the pointer is down — '
          '40 moves used to mean 40 whole-app rebuilds',
    );
    expect(liveUpdates, 1, reason: 'and exactly one update on release');
    expect(
      committedUpdates,
      1,
      reason:
          'the single undo checkpoint is pushed at gesture start, so a '
          'whole drag is still one undo step',
    );

    // The move still lands: the canvas is not just swallowing the gesture.
    expect(
      live.single.startPoint!.dx,
      greaterThan(300),
      reason: 'the flushed list must carry the moved annotation',
    );
  });
}
