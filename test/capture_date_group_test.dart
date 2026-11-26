// Gene - Nov, 25, 2026: Unit tests for date-grouping helpers and 7-day / archive SQLite & StorageService queries.
import 'dart:io';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:snipsnap/database/app_database.dart';
import 'package:snipsnap/models/capture_item.dart';
import 'package:snipsnap/services/database_service.dart';
import 'package:snipsnap/services/storage_service.dart';
import 'package:snipsnap/utils/canvas_projection.dart';
import 'package:snipsnap/utils/capture_date_group.dart';
import 'package:snipsnap/utils/constants.dart';

CaptureItem _capture(String id, DateTime createdAt, {String? filePath}) =>
    CaptureItem(
      id: id,
      filePath: filePath ?? '/tmp/$id.png',
      title: 'Snap $id',
      createdAt: createdAt,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('capture_date_group utilities', () {
    final now = DateTime(2026, 11, 25, 14, 30);

    test('recentHistoryCutoff returns local midnight 6 days before today', () {
      expect(recentHistoryCutoff(now), DateTime(2026, 11, 19));
      expect(kRecentHistoryDays, 7);
    });

    test(
      'formatDateGroupShortLabel and LongLabel format Today, Yesterday, same year, and prior year',
      () {
        expect(
          formatDateGroupShortLabel(DateTime(2026, 11, 25), now: now),
          'Today',
        );
        expect(
          formatDateGroupShortLabel(DateTime(2026, 11, 24), now: now),
          'Yesterday',
        );
        expect(
          formatDateGroupShortLabel(DateTime(2026, 11, 20), now: now),
          'Nov 20',
        );
        expect(
          formatDateGroupShortLabel(DateTime(2025, 12, 31), now: now),
          'Dec 31, 2025',
        );

        expect(
          formatDateGroupLongLabel(DateTime(2026, 11, 25), now: now),
          'Today · Nov 25',
        );
        expect(
          formatDateGroupLongLabel(DateTime(2026, 11, 24), now: now),
          'Yesterday · Nov 24',
        );
        expect(
          formatDateGroupLongLabel(DateTime(2026, 11, 23), now: now),
          'Mon, Nov 23',
        );
        expect(
          formatDateGroupLongLabel(DateTime(2025, 12, 31), now: now),
          'Wed, Dec 31, 2025',
        );
      },
    );

    test(
      'groupCapturesByDate groups by local day newest-first and preserves order within day',
      () {
        final items = [
          _capture('t1', DateTime(2026, 11, 25, 13, 0)),
          _capture('t2', DateTime(2026, 11, 25, 9, 0)),
          _capture('y1', DateTime(2026, 11, 24, 18, 0)),
          _capture('o1', DateTime(2026, 11, 20, 10, 0)),
        ];

        final groups = groupCapturesByDate(items, now: now);
        expect(groups.length, 3);
        expect(groups[0].key, '2026-11-25');
        expect(groups[0].shortLabel, 'Today');
        expect(groups[0].items.map((c) => c.id).toList(), ['t1', 't2']);

        expect(groups[1].key, '2026-11-24');
        expect(groups[1].shortLabel, 'Yesterday');
        expect(groups[1].items.map((c) => c.id).toList(), ['y1']);

        expect(groups[2].key, '2026-11-20');
        expect(groups[2].shortLabel, 'Nov 20');
        expect(groups[2].items.map((c) => c.id).toList(), ['o1']);
      },
    );
  });

  group('7-day and archive DB/Storage queries', () {
    late AppDatabase db;
    late Directory tempDir;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      DatabaseService.db = db;
      tempDir = await Directory.systemTemp.createTemp('snipsnap_date_group_');
    });

    tearDown(() async {
      await db.close();
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    Future<void> insertCaptureWithAnn(String id, DateTime createdAt) async {
      final imgFile = File(p.join(tempDir.path, '$id.png'));
      await imgFile.writeAsBytes(const [1, 2, 3, 4]);
      await db.insertOrUpdateCapture(
        CapturesCompanion(
          id: Value(id),
          filePath: Value(imgFile.path),
          title: Value('Snap $id'),
          createdAt: Value(createdAt),
          width: const Value(100),
          height: const Value(100),
        ),
      );
      await db.saveAnnotationsForCapture(id, [
        AnnotationsCompanion(
          id: Value('ann_$id'),
          captureId: Value(id),
          tool: Value(CanvasTool.pen.name),
          color: const Value(0xFF000000),
          strokeWidth: const Value(2.0),
          fontSize: const Value(14.0),
          createdAt: Value(createdAt),
          zIndex: const Value(0),
          coordSpace: Value(CoordSpace.imagePixels.name),
        ),
      ]);
    }

    test(
      'loadCapturesSinceFromDb, countCapturesBeforeFromDb, and loadCapturesBeforeFromDb partition cleanly at cutoff',
      () async {
        final now = DateTime(2026, 11, 25, 12, 0);
        final cutoff = recentHistoryCutoff(now); // 2026-11-19 00:00:00

        await insertCaptureWithAnn('today', DateTime(2026, 11, 25, 10, 0));
        await insertCaptureWithAnn('day7_edge', DateTime(2026, 11, 19, 0, 0));
        await insertCaptureWithAnn('day8', DateTime(2026, 11, 18, 23, 59));
        await insertCaptureWithAnn('last_month', DateTime(2026, 10, 5, 15, 0));

        final recent = await DatabaseService.loadCapturesSinceFromDb(cutoff);
        expect(recent.map((c) => c.id), ['today', 'day7_edge']);
        expect(recent.first.annotations.map((a) => a.id), ['ann_today']);

        final olderCount = await DatabaseService.countCapturesBeforeFromDb(
          cutoff,
        );
        expect(olderCount, 2);

        final olderPage1 = await DatabaseService.loadCapturesBeforeFromDb(
          cutoff,
          limit: 1,
          offset: 0,
        );
        expect(olderPage1.map((c) => c.id), ['day8']);

        final olderPage2 = await DatabaseService.loadCapturesBeforeFromDb(
          cutoff,
          limit: 1,
          offset: 1,
        );
        expect(olderPage2.map((c) => c.id), ['last_month']);

        final storageRecent = await StorageService.loadRecentHistoryPage(
          since: cutoff,
          limit: 10,
          offset: 0,
        );
        expect(storageRecent.items.map((c) => c.id), ['today', 'day7_edge']);
        expect(storageRecent.olderCount, 2);
        expect(storageRecent.hasMore, isFalse);

        final storageArchive = await StorageService.loadArchiveHistoryPage(
          before: cutoff,
          limit: 10,
          offset: 0,
        );
        expect(storageArchive.items.map((c) => c.id), ['day8', 'last_month']);
        expect(storageArchive.hasMore, isFalse);
      },
    );
  });
}
