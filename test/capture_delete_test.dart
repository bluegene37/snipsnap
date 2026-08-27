import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/database/app_database.dart';
import 'package:snipsnap/models/annotation.dart';
import 'package:snipsnap/models/capture_item.dart';
import 'package:snipsnap/services/database_service.dart';
import 'package:snipsnap/services/storage_service.dart';
import 'package:snipsnap/utils/constants.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    DatabaseService.db = db;
  });

  tearDown(() async => db.close());

  Future<void> seed(String id, String path) async {
    await DatabaseService.saveCaptureToDb(
      CaptureItem(
        id: id,
        filePath: path,
        title: id,
        createdAt: DateTime.now(),
        width: 100,
        height: 80,
        annotations: [
          Annotation(
            id: '$id-a1',
            tool: CanvasTool.line,
            color: const Color(0xFF000000),
            startPoint: const Offset(1, 2),
            endPoint: const Offset(3, 4),
          ),
        ],
      ),
    );
  }

  test('deleting a capture removes its row and its annotations', () async {
    // The gallery's delete used to remove the capture from the in-memory list
    // and unlink the file, then call `saveHistory` — which only rewrites the
    // captures still in the list and never deletes. The row and every
    // annotation row survived, and because the file unlink is deliberately
    // swallowed, a failed unlink brought the whole capture back on next
    // launch with its markup intact.
    await seed('keep', '/tmp/keep.png');
    await seed('drop', '/tmp/drop.png');

    await StorageService.deleteCaptureItem('drop');

    final remaining = await db.getAllCaptures();
    expect(remaining.map((c) => c.id), ['keep']);
    expect(await db.getAnnotationsForCapture('drop'), isEmpty);
    expect(
      await db.getAnnotationsForCapture('keep'),
      hasLength(1),
      reason: 'the surviving capture keeps its markup',
    );
  });

  test(
    'saveHistory alone cannot delete, so the delete call is load-bearing',
    () async {
      // Pins the reason the fix was needed rather than the fix itself: if
      // `saveHistory` ever grew the ability to prune, the extra delete would be
      // redundant and this test says so out loud.
      await seed('keep', '/tmp/keep.png');
      await seed('drop', '/tmp/drop.png');

      await StorageService.saveHistory([
        CaptureItem(
          id: 'keep',
          filePath: '/tmp/keep.png',
          title: 'keep',
          createdAt: DateTime.now(),
          width: 100,
          height: 80,
        ),
      ]);

      expect(
        (await db.getAllCaptures()).map((c) => c.id),
        containsAll(['keep', 'drop']),
      );
    },
  );

  test('the gallery delete handler calls through to the database', () {
    // Source-level, because the handler is an inline closure on `GallerySidebar`
    // inside `MainScreen.build` and cannot be reached without pumping the whole
    // app. What matters is that the call exists at all.
    final source = File('lib/views/main_screen.dart').readAsStringSync();
    final start = source.indexOf('onDeleteItem:');
    expect(start, isNot(-1));
    final end = source.indexOf('onOpenLibraryLocation:', start);
    expect(end, isNot(-1));
    expect(
      source.substring(start, end),
      contains('StorageService.deleteCaptureItem('),
      reason: 'deleting a capture must delete its rows, not just its file',
    );
  });
}
