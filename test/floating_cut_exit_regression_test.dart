// Regression: ISSUE-001 — a cut-and-moved region existed only in memory from
// the cut until the user clicked elsewhere, while its hole was already in the
// capture file. Quitting in that window (Cmd+Q, the Quit menu item, closing
// the window) threw the pixels away for good: the hole stayed, the piece was
// never written.
// Found by /qa on 2026-09-02
// Report: .gstack/qa-reports/qa-report-snipsnap-2026-09-02.md
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:snipsnap/models/annotation.dart';
import 'package:snipsnap/utils/constants.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/editor_canvas.dart';

import 'support/base_image_settle.dart';

const _size = Size(400, 300);

Widget _canvas({
  required String imagePath,
  required GlobalKey repaintKey,
  required List<Annotation> added,
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
            activeTool: CanvasTool.select,
            activeColor: const Color(0xFF000000),
            strokeWidth: 4,
            fontSize: 16,
            isFilled: false,
            stepCounter: 1,
            onAnnotationAdded: (_) {},
            // A dropped cut arrives as a whole-list update, not an add: the
            // cut already pushed the undo state when it lifted the pixels.
            onAnnotationsLiveUpdated: (list) => added
              ..clear()
              ..addAll(list),
            onStepCounterIncremented: (_) {},
            repaintBoundaryKey: repaintKey,
          ),
        ),
      ),
    ),
  );
}

Future<void> _drag(WidgetTester tester, Offset from, Offset to) async {
  await tester.runAsync(() async {
    final gesture = await tester.startGesture(
      from,
      kind: PointerDeviceKind.mouse,
    );
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

/// What the platform sends when the user quits: the embedder asks the
/// framework whether it may exit, and every exit observer answers first.
Future<String> _requestAppExit(WidgetTester tester) async {
  late String response;
  await tester.runAsync(() async {
    final message = const JSONMethodCodec().encodeMethodCall(
      const MethodCall('System.requestAppExit'),
    );
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage('flutter/platform', message, (reply) {
          final decoded = const JSONMethodCodec().decodeEnvelope(reply!);
          response = (decoded as Map)['response'] as String;
        });
  });
  await tester.pumpAndSettle();
  return response;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('snipsnap_cut_exit');
    path = '${dir.path}/capture.png';
    final image = img.Image(
      width: _size.width.toInt(),
      height: _size.height.toInt(),
    );
    img.fill(image, color: img.ColorRgb8(220, 30, 30));
    File(path).writeAsBytesSync(img.encodePng(image));
  });

  tearDown(() => dir.deleteSync(recursive: true));

  testWidgets('an exit request commits a cut that is still floating', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(700, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final added = <Annotation>[];
    final repaintKey = GlobalKey();
    await tester.runAsync(() async {
      await tester.pumpWidget(
        _canvas(imagePath: path, repaintKey: repaintKey, added: added),
      );
      await settleBaseImage(tester, expected: _size);
    });
    await tester.pumpAndSettle();

    final box = repaintKey.currentContext!.findRenderObject() as RenderBox;
    Offset at(double dx, double dy) => box.localToGlobal(Offset(dx, dy));

    // Marquee a region, then drag from inside it: the pixels leave the file
    // and float, uncommitted — the state the user quits from.
    await _drag(tester, at(120, 120), at(240, 220));
    await _drag(tester, at(180, 170), at(210, 190));
    expect(
      _redPixelCount(path),
      lessThan(_size.width.toInt() * _size.height.toInt()),
      reason:
          'the cut must actually have removed pixels from the file, '
          'otherwise the rest of this test proves nothing',
    );
    expect(added, isEmpty, reason: 'nothing has been committed yet');

    expect(await _requestAppExit(tester), 'exit');

    expect(
      added.map((a) => a.tool),
      [CanvasTool.imagePatch],
      reason:
          'the exit request must drop the floating cut as a piece before '
          'the process is allowed to go, or the pixels are lost with it',
    );
    expect(added.single.patchBytes, isNotNull);
  });

  testWidgets('an exit request with nothing floating changes nothing', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(700, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final added = <Annotation>[];
    final repaintKey = GlobalKey();
    await tester.runAsync(() async {
      await tester.pumpWidget(
        _canvas(imagePath: path, repaintKey: repaintKey, added: added),
      );
      await settleBaseImage(tester, expected: _size);
    });
    await tester.pumpAndSettle();

    expect(await _requestAppExit(tester), 'exit');
    expect(added, isEmpty);
    expect(
      _redPixelCount(path),
      _size.width.toInt() * _size.height.toInt(),
      reason: 'the file is untouched',
    );
  });
}
