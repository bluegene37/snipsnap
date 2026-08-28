import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:snipsnap/database/app_database.dart';
import 'package:snipsnap/services/database_service.dart';
import 'package:snipsnap/views/editor_canvas.dart';
import 'package:snipsnap/views/main_screen.dart';

/// Boots the real app over one seeded capture.
///
/// Undo lives in `MainScreen` and the leftover chrome lives in `EditorCanvas`,
/// so nothing short of the whole tree can show whether one clears the other.
/// `path_provider` and `hotkey_manager` are stubbed; the database is in memory.
Future<Directory> _bootApp(WidgetTester tester) async {
  final dir = Directory.systemTemp.createTempSync('snipsnap_undo');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => dir.path,
      );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('dev.leanflutter.plugins/hotkey_manager'),
        (call) async => null,
      );
  final db = AppDatabase(NativeDatabase.memory());
  DatabaseService.db = db;
  // Deliberately never closed. flutter_test keeps the widget tree mounted
  // after a test body ends; the NEXT test's pumpWidget is what unmounts this
  // MainScreen, and its dispose() saves the active capture to this database.
  // A tearDown close therefore races that save and surfaces as
  // "Can't re-open a database after closing it" in the following test.
  // The in-memory database is reclaimed when the test isolate exits.

  final captures = Directory('${dir.path}/SnipSnap/Captures')
    ..createSync(recursive: true);
  final image = img.Image(width: 1200, height: 900);
  img.fill(image, color: img.ColorRgb8(240, 240, 240));
  File('${captures.path}/snap_1.png').writeAsBytesSync(img.encodePng(image));

  await tester.runAsync(() async {
    await tester.pumpWidget(const MainScreen());
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await tester.pump();
  });
  await _settle(tester);
  return dir;
}

Finder get _canvas => find.byType(EditorCanvas);

Finder get _boundary =>
    find.descendant(of: _canvas, matching: find.byType(RepaintBoundary)).first;

/// Raw pixels of the editor surface.
Future<List<int>> _snapshot(WidgetTester tester) async {
  late List<int> out;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(_boundary);
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ImageByteFormat.rawRgba);
    image.dispose();
    out = data!.buffer.asUint8List();
  });
  return out;
}

/// Differing pixels inside [region] only, so a comparison can ignore parts of
/// the surface a step legitimately changed.
int _differingIn(List<int> a, List<int> b, int surfaceWidth, Rect region) {
  var count = 0;
  for (var y = region.top.toInt(); y < region.bottom.toInt(); y++) {
    for (var x = region.left.toInt(); x < region.right.toInt(); x++) {
      final i = (y * surfaceWidth + x) * 4;
      if (i + 2 >= a.length) continue;
      if (a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2]) count++;
    }
  }
  return count;
}

int _differingPixels(List<int> a, List<int> b) {
  var count = 0;
  for (var i = 0; i < a.length; i += 4) {
    if (a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2]) count++;
  }
  return count;
}

/// Pumps to rest and drains the layout overflows the Ahem test font causes in
/// the fixed-width side panels — the same harness artifact
/// `style_picker_test.dart` documents. They are not what these tests measure.
Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  while (tester.takeException() != null) {}
}

Future<void> _drag(WidgetTester tester, Offset from, Offset to) async {
  final gesture = await tester.startGesture(
    from,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump(const Duration(milliseconds: 16));
  for (var i = 1; i <= 40; i++) {
    await gesture.moveTo(Offset.lerp(from, to, i / 40)!);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await _settle(tester);
}

Future<void> _undo(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
  await _settle(tester);
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 300)),
  );
  await _settle(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('undo leaves nothing of the gesture it reversed on screen', (
    tester,
  ) async {
    // The report: undo ran, but the shape that had just been dragged stayed on
    // screen. The annotation list was restored correctly — what stayed was the
    // canvas's own selection chrome, which lives outside the undo snapshot and
    // had nothing to tell it the state underneath had been replaced.
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final dir = await _bootApp(tester);
    addTearDown(() => dir.deleteSync(recursive: true));

    final origin = tester
        .renderObject<RenderBox>(_canvas)
        .localToGlobal(Offset.zero);

    // Click first: the app's outer Focus otherwise swallows the tool shortcut.
    await tester.tapAt(
      origin + const Offset(600, 400),
      kind: PointerDeviceKind.mouse,
    );
    await _settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR); // shape
    await _settle(tester);

    await _drag(
      tester,
      origin + const Offset(200, 200),
      origin + const Offset(420, 340),
    );
    expect(tester.widget<EditorCanvas>(_canvas).annotations, hasLength(1));

    await tester.sendKeyEvent(LogicalKeyboardKey.keyV); // select
    await _settle(tester);
    final placed = await _snapshot(tester);

    await _drag(
      tester,
      origin + const Offset(310, 270),
      origin + const Offset(520, 430),
    );
    final moved = await _snapshot(tester);
    expect(
      _differingPixels(moved, placed),
      greaterThan(1000),
      reason: 'the move must actually have changed the picture',
    );

    await _undo(tester);

    expect(
      _differingPixels(await _snapshot(tester), placed),
      0,
      reason:
          'every pixel must return to the pre-drag state — including the '
          'handles drawn around the shape that was being dragged',
    );
  });

  testWidgets('undo clears a live marquee', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final dir = await _bootApp(tester);
    addTearDown(() => dir.deleteSync(recursive: true));

    final origin = tester
        .renderObject<RenderBox>(_canvas)
        .localToGlobal(Offset.zero);

    await tester.tapAt(
      origin + const Offset(600, 400),
      kind: PointerDeviceKind.mouse,
    );
    await _settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await _settle(tester);
    await _drag(
      tester,
      origin + const Offset(200, 200),
      origin + const Offset(420, 340),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await _settle(tester);
    final clean = await _snapshot(tester);

    // Marquee over empty canvas, well clear of the shape. The boundary sits
    // 20px below the canvas origin (the viewer's vertical padding), so the
    // region is the drag rectangle shifted up by that much and inflated to
    // take in the handles drawn on its corners.
    await _drag(
      tester,
      origin + const Offset(650, 200),
      origin + const Offset(860, 380),
    );
    final surfaceWidth = tester
        .renderObject<RenderRepaintBoundary>(_boundary)
        .size
        .width
        .toInt();
    final region = const Rect.fromLTRB(650, 180, 860, 360).inflate(24);

    expect(
      _differingIn(await _snapshot(tester), clean, surfaceWidth, region),
      greaterThan(500),
      reason: 'the marquee must be visible before undo',
    );

    await _undo(tester);

    // Only the marquee's own region: the same undo also removes the shape,
    // which is correct and lives elsewhere on the surface.
    expect(
      _differingIn(await _snapshot(tester), clean, surfaceWidth, region),
      0,
      reason: 'the dragged marquee must not outlive the undo',
    );
  });
}
