// Regression: ISSUE-004 — deleting a capture raced the annotation write its
// own pre-delete sync had just started. That write is two steps (capture
// row, then annotation rows); the delete transaction ran between them, so
// the capture went and its annotation rows came back — orphaned, patch blobs
// and all, for every capture ever deleted.
// Found by /qa on 2026-09-02
// Report: .gstack/qa-reports/qa-report-snipsnap-2026-09-02.md
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:snipsnap/database/app_database.dart';
import 'package:snipsnap/services/database_service.dart';
import 'package:snipsnap/views/editor_canvas.dart';
import 'package:snipsnap/views/main_screen.dart';

/// Boots the real app over one seeded capture — the harness from
/// `undo_clears_canvas_state_test.dart`: `path_provider` and `hotkey_manager`
/// stubbed, the database in memory.
Future<({Directory dir, AppDatabase db})> _bootApp(WidgetTester tester) async {
  final dir = Directory.systemTemp.createTempSync('snipsnap_delete_orphan');
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
  // A guard, not a reproduction: the app's database runs on a worker isolate,
  // where every query is a round trip and the delete could land between the
  // two halves of the pre-delete save. An in-memory database on this isolate
  // runs those halves back to back, so this test passed even before the fix;
  // the race itself was reproduced and re-verified on the live app.
  // Deliberately never closed: MainScreen's dispose saves into it during
  // teardown, and a closed database would turn that into a failure.
  final db = AppDatabase(NativeDatabase.memory());
  DatabaseService.db = db;

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
  return (dir: dir, db: db);
}

Finder get _canvas => find.byType(EditorCanvas);

/// Pumps to rest and drains the layout overflows the Ahem test font causes in
/// the fixed-width side panels — a harness artifact, not what is measured.
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

Future<void> _cleanUp(WidgetTester tester, Directory dir) async {
  await tester.pumpWidget(const SizedBox());
  await _settle(tester);
  imageCache.clear();
  imageCache.clearLiveImages();
  for (var attempt = 0; attempt < 10; attempt++) {
    try {
      dir.deleteSync(recursive: true);
      return;
    } on FileSystemException {
      sleep(const Duration(milliseconds: 100));
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('deleting a capture leaves none of its annotation rows behind', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final app = await _bootApp(tester);
    addTearDown(() => _cleanUp(tester, app.dir));

    final origin = tester
        .renderObject<RenderBox>(_canvas)
        .localToGlobal(Offset.zero);

    // Draw one annotation the way the undo test does: click for focus, pick
    // the shape tool, drag it out. Its write is what the delete then races.
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
    expect(tester.widget<EditorCanvas>(_canvas).annotations, hasLength(1));
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(deadline)) {
        if ((await app.db.select(app.db.annotations).get()).isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    });
    expect(await app.db.select(app.db.annotations).get(), hasLength(1));

    await tester.tap(find.byTooltip('Delete Capture'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1000)),
    );
    await _settle(tester);

    expect(await app.db.select(app.db.captures).get(), isEmpty);
    expect(
      await app.db.select(app.db.annotations).get(),
      isEmpty,
      reason:
          'the delete must wait for the pre-delete annotation write: a row '
          'without its capture is a leak, patch blob included',
    );
  });
}
