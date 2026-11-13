import 'dart:ui';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/database/app_database.dart';
import 'package:snipsnap/models/annotation.dart';
import 'package:snipsnap/models/capture_item.dart';
import 'package:snipsnap/services/database_service.dart';
import 'package:snipsnap/services/storage_service.dart';
import 'package:snipsnap/utils/constants.dart';

CaptureItem _makeCapture(String id) {
  return CaptureItem(
    id: id,
    filePath: '/tmp/$id.png',
    title: id,
    createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    width: 200,
    height: 120,
    annotations: [
      Annotation(
        id: '$id-ann',
        tool: CanvasTool.line,
        color: const Color(0xFFFF0000),
        startPoint: const Offset(10, 10),
        endPoint: const Offset(40, 40),
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    DatabaseService.db = db;
  });

  tearDown(() async {
    await db.close();
  });

  test(
    'saveHistory does not throw ConcurrentModificationError when source list mutates mid-flight',
    () async {
      final liveCaptures = List<CaptureItem>.generate(
        60,
        (i) => _makeCapture('cap_$i'),
      );

      final saveFuture = StorageService.saveHistory(liveCaptures);

      // Simulate rapid gallery deletions and new capture insertions while saveHistory awaits SQLite.
      liveCaptures.removeWhere((c) => c.id == 'cap_0' || c.id == 'cap_10');
      await Future<void>.delayed(Duration.zero);
      liveCaptures.removeAt(5);
      liveCaptures.insert(0, _makeCapture('cap_new_1'));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      liveCaptures.removeWhere((c) => c.id == 'cap_30');
      liveCaptures.insert(0, _makeCapture('cap_new_2'));

      await expectLater(saveFuture, completes);
    },
  );

  test(
    'deleteCaptureItem during an in-flight saveHistory never resurrects deleted rows or annotations',
    () async {
      final liveCaptures = List<CaptureItem>.generate(
        40,
        (i) => _makeCapture('item_$i'),
      );

      final saveFuture = StorageService.saveHistory(liveCaptures);

      const deletedIds = ['item_5', 'item_15', 'item_25', 'item_35'];
      for (final id in deletedIds) {
        liveCaptures.removeWhere((c) => c.id == id);
        await StorageService.deleteCaptureItem(id);
      }

      await saveFuture;

      final persistedIds = (await db.getAllCaptures()).map((c) => c.id).toSet();
      for (final id in deletedIds) {
        expect(
          persistedIds,
          isNot(contains(id)),
          reason: '$id was deleted while bulk save was active',
        );
        expect(
          await db.getAnnotationsForCapture(id),
          isEmpty,
          reason: '$id annotations must remain deleted',
        );
      }
      expect(persistedIds, contains('item_0'));
      expect(persistedIds, contains('item_39'));
    },
  );
}
