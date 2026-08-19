import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/database/app_database.dart';
import 'package:snipsnap/models/capture_item.dart';
import 'package:snipsnap/services/database_service.dart';
import 'package:snipsnap/services/storage_service.dart';
import 'package:snipsnap/utils/canvas_projection.dart';

/// The v3 schema, verbatim: no `coord_space` column anywhere. Everything the
/// v4 migration is supposed to add has to be added by the migration, not by
/// this fixture, or the test proves nothing.
const _v3Captures = '''
CREATE TABLE captures (
  id TEXT NOT NULL,
  file_path TEXT NOT NULL,
  title TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  width INTEGER NOT NULL DEFAULT 0,
  height INTEGER NOT NULL DEFAULT 0,
  tags TEXT NULL,
  PRIMARY KEY (id)
);
''';

const _v3Annotations = '''
CREATE TABLE annotations (
  id TEXT NOT NULL,
  capture_id TEXT NOT NULL,
  tool TEXT NOT NULL,
  color INTEGER NOT NULL,
  stroke_width REAL NOT NULL,
  font_size REAL NOT NULL,
  is_filled INTEGER NOT NULL DEFAULT 0 CHECK ("is_filled" IN (0, 1)),
  text_content TEXT NULL,
  points_json TEXT NULL,
  rect_json TEXT NULL,
  step_number INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  start_x REAL NULL,
  start_y REAL NULL,
  end_x REAL NULL,
  end_y REAL NULL,
  opacity REAL NULL,
  props_json TEXT NULL,
  z_index INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (id)
);
''';

const _v3Shortcuts = '''
CREATE TABLE shortcuts (
  action TEXT NOT NULL,
  key_id INTEGER NOT NULL,
  key_label TEXT NOT NULL,
  meta INTEGER NOT NULL DEFAULT 0 CHECK ("meta" IN (0, 1)),
  ctrl INTEGER NOT NULL DEFAULT 0 CHECK ("ctrl" IN (0, 1)),
  shift INTEGER NOT NULL DEFAULT 0 CHECK ("shift" IN (0, 1)),
  alt INTEGER NOT NULL DEFAULT 0 CHECK ("alt" IN (0, 1)),
  PRIMARY KEY (action)
);
''';

const _v3AppSettings = '''
CREATE TABLE app_settings (
  key TEXT NOT NULL,
  value TEXT NOT NULL,
  PRIMARY KEY (key)
);
''';

/// One capture plus one viewport-space line annotation on it, as a pre-v4
/// build would have left them.
String _captureRow(String id, int createdAt) => '''
INSERT INTO captures (id, file_path, title, created_at, width, height)
VALUES ('$id', '/tmp/$id.png', '$id', $createdAt, 0, 0);
''';

String _annotationRow(String captureId) => '''
INSERT INTO annotations
  (id, capture_id, tool, color, stroke_width, font_size, created_at,
   start_x, start_y, end_x, end_y, z_index)
VALUES
  ('ann_$captureId', '$captureId', 'line', 4278190080, 3.0, 16.0, 1700000000,
   100.0, 50.0, 300.0, 150.0, 0);
''';

/// Opens an in-memory database that already contains v3 data at
/// `user_version = 3`, so constructing [AppDatabase] over it runs the real
/// `onUpgrade(3, 4)` path.
AppDatabase _openV3AtV4(List<String> captureIds) {
  return AppDatabase(NativeDatabase.memory(setup: (raw) {
    raw.execute(_v3Captures);
    raw.execute(_v3Annotations);
    raw.execute(_v3Shortcuts);
    raw.execute(_v3AppSettings);
    var stamp = 1700000000;
    for (final id in captureIds) {
      raw.execute(_captureRow(id, stamp));
      raw.execute(_annotationRow(id));
      stamp -= 1000; // descending createdAt keeps load order stable
    }
    raw.execute('PRAGMA user_version = 3;');
  }));
}

/// The stored coordinate-space stamp for a capture's single annotation row,
/// read straight out of SQLite rather than through the model, because the
/// stamp is exactly what the model layer would paper over.
Future<String> _storedSpace(AppDatabase db, String captureId) async {
  final rows = await db.getAnnotationsForCapture(captureId);
  return rows.single.coordSpace;
}

Future<double> _storedStartX(AppDatabase db, String captureId) async {
  final rows = await db.getAnnotationsForCapture(captureId);
  return rows.single.startX!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;

  setUp(() {
    db = _openV3AtV4(['active', 'legacy_a', 'legacy_b']);
    DatabaseService.db = db;
  });

  tearDown(() async {
    await db.close();
  });

  test('the v3 -> v4 migration runs and defaults existing rows to viewport',
      () async {
    // Reading anything opens the database, which is what triggers onUpgrade.
    final items = await DatabaseService.loadCapturesFromDb();

    expect(items, hasLength(3));
    for (final item in items) {
      expect(await _storedSpace(db, item.id), CoordSpace.viewport.name,
          reason: 'the added column must default pre-v4 rows to viewport; '
              'defaulting to imagePixels would silently declare untouched '
              'legacy data already converted');
      expect(item.annotationsNeedConversion, isTrue,
          reason: 'a viewport row must surface as needing conversion');
      expect(item.annotations.single.startPoint, const Offset(100, 50));
    }
  });

  test('converting one capture and re-saving it stamps only that capture',
      () async {
    final items = await DatabaseService.loadCapturesFromDb();
    final active = items.firstWhere((i) => i.id == 'active');

    // What main_screen's _convertActiveCaptureAnnotations does: convert, then
    // clear the flag, then persist. 2000x1000 image in a 1000x500 canvas is a
    // clean 2x with no letterbox, so the arithmetic is checkable by hand.
    final result = convertLegacyAnnotationsChecked(
      annotations: active.annotations,
      imageSize: const Size(2000, 1000),
      canvasSize: const Size(1000, 500),
    );
    expect(result.converted, isTrue);

    final converted = active.copyWith(
      annotations: result.annotations,
      annotationsNeedConversion: false,
      width: 2000,
      height: 1000,
    );

    // Path 1: the singular save.
    await StorageService.saveCaptureItem(converted);

    expect(await _storedSpace(db, 'active'), CoordSpace.imagePixels.name);
    expect(await _storedStartX(db, 'active'), closeTo(200.0, 1e-6));
    expect(await _storedSpace(db, 'legacy_a'), CoordSpace.viewport.name);
    expect(await _storedStartX(db, 'legacy_a'), closeTo(100.0, 1e-6));
  });

  test(
      'saveHistory over a mixed library never stamps an unconverted capture — '
      'the whole-library write path is guarded too, not just the singular one',
      () async {
    // This is the Finding 1 reproduction. Only the active capture is ever
    // converted; then the user takes one screenshot, which rewrites the entire
    // library through saveHistory. Before the guard, that stamped every
    // remaining capture `imagePixels` while its numbers were still viewport,
    // and the next launch saw nothing left to convert.
    final items = await DatabaseService.loadCapturesFromDb();
    final active = items.firstWhere((i) => i.id == 'active');

    final result = convertLegacyAnnotationsChecked(
      annotations: active.annotations,
      imageSize: const Size(2000, 1000),
      canvasSize: const Size(1000, 500),
    );
    final converted = active.copyWith(
      annotations: result.annotations,
      annotationsNeedConversion: false,
      width: 2000,
      height: 1000,
    );

    final library = [
      converted,
      ...items.where((i) => i.id != 'active'),
      // A brand-new capture, as _addCaptureFromPath would insert it.
      CaptureItem(
        id: 'fresh',
        filePath: '/tmp/fresh.png',
        title: 'fresh',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1710000000000),
        width: 800,
        height: 600,
      ),
    ];

    // Path 2: the plural save.
    await StorageService.saveHistory(library);

    expect(await _storedSpace(db, 'active'), CoordSpace.imagePixels.name);
    expect(await _storedStartX(db, 'active'), closeTo(200.0, 1e-6));

    for (final id in ['legacy_a', 'legacy_b']) {
      expect(await _storedSpace(db, id), CoordSpace.viewport.name,
          reason: '$id was never converted, so saveHistory must not claim it '
              'is in image pixels');
      expect(await _storedStartX(db, id), closeTo(100.0, 1e-6),
          reason: '$id must keep its original viewport numbers');
    }

    // The refusal is data-preserving, not data-losing: reloading still reports
    // the untouched captures as owing a conversion, so they get one.
    final reloaded = await DatabaseService.loadCapturesFromDb();
    for (final id in ['legacy_a', 'legacy_b']) {
      expect(reloaded.firstWhere((i) => i.id == id).annotationsNeedConversion,
          isTrue);
    }
    expect(
        reloaded.firstWhere((i) => i.id == 'active').annotationsNeedConversion,
        isFalse);
  });

  test('the guard withholds annotation rows only, not capture metadata',
      () async {
    // Dimensions recovered by decoding a pre-Task-1 capture are exactly what a
    // later conversion needs, and they carry no coordinate space of their own,
    // so the guard must not swallow them along with the annotations.
    final items = await DatabaseService.loadCapturesFromDb();
    final legacy = items.firstWhere((i) => i.id == 'legacy_a');
    expect(legacy.hasDimensions, isFalse);

    await StorageService.saveCaptureItem(
      legacy.copyWith(width: 1920, height: 1080),
    );

    final reloaded = await DatabaseService.loadCapturesFromDb();
    final after = reloaded.firstWhere((i) => i.id == 'legacy_a');
    expect(after.width, 1920);
    expect(after.height, 1080);
    expect(await _storedSpace(db, 'legacy_a'), CoordSpace.viewport.name);
    expect(after.annotationsNeedConversion, isTrue);
  });

  test('a capture with no annotations is never flagged, so it always saves',
      () async {
    // Guards keyed on a flag are only safe if the flag is false in the ordinary
    // case. An empty annotation list has no viewport rows to find.
    final empty = CaptureItem(
      id: 'empty',
      filePath: '/tmp/empty.png',
      title: 'empty',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1710000001000),
    );
    expect(DatabaseService.canPersistAnnotations(empty), isTrue);

    await StorageService.saveCaptureItem(empty);
    final reloaded = await DatabaseService.loadCapturesFromDb();
    expect(reloaded.firstWhere((i) => i.id == 'empty').annotationsNeedConversion,
        isFalse);
  });
}
