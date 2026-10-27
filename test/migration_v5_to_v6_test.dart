// Gene - Oct, 27, 2026: Migration test verifying upgrading SQLite schema from v5 to v6 adds video recording columns to captures.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/database/app_database.dart';
import 'package:snipsnap/models/capture_item.dart';
import 'package:snipsnap/services/database_service.dart';

const _v5Captures = '''
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

const _v5Annotations = '''
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
  coord_space TEXT NOT NULL DEFAULT 'viewport',
  patch_bytes BLOB NULL,
  PRIMARY KEY (id)
);
''';

const _v5Shortcuts = '''
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

const _v5AppSettings = '''
CREATE TABLE app_settings (
  key TEXT NOT NULL,
  value TEXT NOT NULL,
  PRIMARY KEY (key)
);
''';

AppDatabase _openV5AtV6() {
  return AppDatabase(
    NativeDatabase.memory(
      setup: (raw) {
        raw.execute(_v5Captures);
        raw.execute(_v5Annotations);
        raw.execute(_v5Shortcuts);
        raw.execute(_v5AppSettings);
        raw.execute('''
INSERT INTO captures (id, file_path, title, created_at, width, height)
VALUES ('legacy_snap', '/tmp/legacy_snap.png', 'Legacy Snap', 1700000000, 1920, 1080);
''');
        raw.execute('PRAGMA user_version = 5;');
      },
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;

  setUp(() {
    db = _openV5AtV6();
    DatabaseService.db = db;
  });

  tearDown(() async {
    await db.close();
  });

  test('v5 to v6 migration adds mediaType, durationMs, hasAudio, and thumbnailPath', () async {
    // 1. Verify schema version upgraded to 6
    expect(db.schemaVersion, 6);

    // 2. Load existing legacy capture; verify default values are applied
    final items = await DatabaseService.loadCapturesFromDb();
    expect(items.length, 1);
    final legacy = items.single;
    expect(legacy.id, 'legacy_snap');
    expect(legacy.mediaType, CaptureMediaType.image);
    expect(legacy.isImage, isTrue);
    expect(legacy.isVideo, isFalse);
    expect(legacy.durationMs, 0);
    expect(legacy.hasAudio, isFalse);
    expect(legacy.thumbnailPath, isNull);

    // 3. Save a new video capture item to verify columns accept video metadata
    final video = CaptureItem(
      id: 'rec_100',
      filePath: '/tmp/rec_100.mp4',
      title: 'Screen Recording 1',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1710000000),
      width: 2560,
      height: 1440,
      mediaType: CaptureMediaType.video,
      durationMs: 42000,
      hasAudio: true,
      thumbnailPath: '/tmp/rec_100_thumb.png',
    );
    await DatabaseService.saveCaptureToDb(video);

    // 4. Reload from database and verify persistence of video fields
    final reloaded = await DatabaseService.loadCapturesFromDb();
    expect(reloaded.length, 2);
    final savedVideo = reloaded.firstWhere((i) => i.id == 'rec_100');
    expect(savedVideo.mediaType, CaptureMediaType.video);
    expect(savedVideo.isVideo, isTrue);
    expect(savedVideo.durationMs, 42000);
    expect(savedVideo.hasAudio, isTrue);
    expect(savedVideo.thumbnailPath, '/tmp/rec_100_thumb.png');
  });
}
