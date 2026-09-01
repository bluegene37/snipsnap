// Regression: ISSUE-001 — the sandbox migration copied the database verbatim,
// so every captures.file_path still pointed into the abandoned container. The
// startup library scan then re-registered each migrated file as a brand-new
// capture (every capture appeared twice in the gallery) and edits through the
// original row kept writing into the container, silently forking the copies.
// Found by /qa on 2026-09-01
// Report: .gstack/qa-reports/qa-report-snipsnap-2026-09-01.md
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/services/sandbox_migration.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('snipsnap_repair_'));
  tearDown(() => root.deleteSync(recursive: true));

  /// Creates a fixture database with the columns the repair touches, mirroring
  /// the real schema's names.
  String createDb(String path) {
    File(path).parent.createSync(recursive: true);
    final db = sql.sqlite3.open(path);
    db.execute('''
      CREATE TABLE captures (
        id TEXT NOT NULL PRIMARY KEY,
        file_path TEXT NOT NULL,
        title TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        width INTEGER NOT NULL DEFAULT 0,
        height INTEGER NOT NULL DEFAULT 0
      );
    ''');
    db.execute('''
      CREATE TABLE annotations (
        id TEXT NOT NULL PRIMARY KEY,
        capture_id TEXT NOT NULL,
        tool TEXT NOT NULL
      );
    ''');
    db.execute('''
      CREATE TABLE app_settings (
        key TEXT NOT NULL PRIMARY KEY,
        value TEXT NOT NULL
      );
    ''');
    db.close();
    return path;
  }

  void insertCapture(String dbPath, String id, String filePath) {
    final db = sql.sqlite3.open(dbPath);
    db.execute(
      "INSERT INTO captures (id, file_path, title, created_at) "
      "VALUES (?, ?, 'Snap', 0)",
      [id, filePath],
    );
    db.close();
  }

  List<Map<String, Object?>> captureRows(String dbPath) {
    final db = sql.sqlite3.open(dbPath);
    final rows = db
        .select('SELECT id, file_path FROM captures ORDER BY id')
        .map((r) => {'id': r['id'], 'file_path': r['file_path']})
        .toList();
    db.close();
    return rows;
  }

  test('rewrites container paths so the scan cannot duplicate them', () {
    final oldRoot = '${root.path}/container/Documents/SnipSnap';
    final newRoot = '${root.path}/home/Documents/SnipSnap';
    Directory('$oldRoot/Captures').createSync(recursive: true);
    File('$oldRoot/Captures/snap_1.png').writeAsStringSync('pixels');
    Directory('$newRoot/Captures').createSync(recursive: true);
    File('$newRoot/Captures/snap_1.png').writeAsStringSync('pixels');
    final dbPath = createDb('$newRoot/snipsnap_local.sqlite');
    insertCapture(dbPath, 'cap1', '$oldRoot/Captures/snap_1.png');

    SandboxMigration.repairCapturePaths(
      dbPath: dbPath,
      oldRoot: oldRoot,
      newRoot: newRoot,
    );

    expect(captureRows(dbPath), [
      {'id': 'cap1', 'file_path': '$newRoot/Captures/snap_1.png'},
    ]);
  });

  test(
    'deletes an unannotated scan duplicate and remaps active_capture_id',
    () {
      final oldRoot = '${root.path}/container/Documents/SnipSnap';
      final newRoot = '${root.path}/home/Documents/SnipSnap';
      Directory('$oldRoot/Captures').createSync(recursive: true);
      File('$oldRoot/Captures/snap_1.png').writeAsStringSync('pixels');
      Directory('$newRoot/Captures').createSync(recursive: true);
      File('$newRoot/Captures/snap_1.png').writeAsStringSync('pixels');
      final dbPath = createDb('$newRoot/snipsnap_local.sqlite');
      insertCapture(dbPath, 'original', '$oldRoot/Captures/snap_1.png');
      insertCapture(dbPath, 'scan-twin', '$newRoot/Captures/snap_1.png');
      final db = sql.sqlite3.open(dbPath);
      db.execute(
        "INSERT INTO app_settings (key, value) "
        "VALUES ('active_capture_id', 'scan-twin')",
      );
      db.close();

      SandboxMigration.repairCapturePaths(
        dbPath: dbPath,
        oldRoot: oldRoot,
        newRoot: newRoot,
      );

      expect(captureRows(dbPath), [
        {'id': 'original', 'file_path': '$newRoot/Captures/snap_1.png'},
      ]);
      final settings = sql.sqlite3.open(dbPath);
      final active = settings
          .select(
            "SELECT value FROM app_settings WHERE key = 'active_capture_id'",
          )
          .first['value'];
      settings.close();
      expect(active, 'original');
    },
  );

  test('newer container bytes replace the stale migrated copy', () {
    final oldRoot = '${root.path}/container/Documents/SnipSnap';
    final newRoot = '${root.path}/home/Documents/SnipSnap';
    Directory('$oldRoot/Captures').createSync(recursive: true);
    Directory('$newRoot/Captures').createSync(recursive: true);
    final containerFile = File('$oldRoot/Captures/snap_1.png')
      ..writeAsStringSync('edited after migration');
    final migratedCopy = File('$newRoot/Captures/snap_1.png')
      ..writeAsStringSync('stale snapshot');
    // The copy predates the container edits.
    migratedCopy.setLastModifiedSync(
      containerFile.statSync().modified.subtract(const Duration(hours: 1)),
    );
    final dbPath = createDb('$newRoot/snipsnap_local.sqlite');
    insertCapture(dbPath, 'cap1', containerFile.path);

    SandboxMigration.repairCapturePaths(
      dbPath: dbPath,
      oldRoot: oldRoot,
      newRoot: newRoot,
    );

    expect(migratedCopy.readAsStringSync(), 'edited after migration');
    // The container copy stays behind as the safety net.
    expect(containerFile.existsSync(), isTrue);
  });

  test('an annotated duplicate is a fork and both rows survive', () {
    final oldRoot = '${root.path}/container/Documents/SnipSnap';
    final newRoot = '${root.path}/home/Documents/SnipSnap';
    Directory('$oldRoot/Captures').createSync(recursive: true);
    File('$oldRoot/Captures/snap_1.png').writeAsStringSync('a');
    Directory('$newRoot/Captures').createSync(recursive: true);
    File('$newRoot/Captures/snap_1.png').writeAsStringSync('b');
    final dbPath = createDb('$newRoot/snipsnap_local.sqlite');
    insertCapture(dbPath, 'original', '$oldRoot/Captures/snap_1.png');
    insertCapture(dbPath, 'scan-twin', '$newRoot/Captures/snap_1.png');
    final db = sql.sqlite3.open(dbPath);
    db.execute(
      "INSERT INTO annotations (id, capture_id, tool) "
      "VALUES ('a1', 'scan-twin', 'pen')",
    );
    db.close();

    SandboxMigration.repairCapturePaths(
      dbPath: dbPath,
      oldRoot: oldRoot,
      newRoot: newRoot,
    );

    expect(captureRows(dbPath), [
      {'id': 'original', 'file_path': '$oldRoot/Captures/snap_1.png'},
      {'id': 'scan-twin', 'file_path': '$newRoot/Captures/snap_1.png'},
    ]);
    expect(File('$newRoot/Captures/snap_1.png').readAsStringSync(), 'b');
  });

  test('tolerates a file that is not a database', () {
    final dbPath = '${root.path}/snipsnap_local.sqlite';
    File(dbPath).writeAsStringSync('not a database');

    expect(
      () => SandboxMigration.repairCapturePaths(
        dbPath: dbPath,
        oldRoot: '${root.path}/old',
        newRoot: '${root.path}/new',
      ),
      returnsNormally,
    );
  });

  test('runIfNeeded repairs the database it just migrated', () async {
    final home = '${root.path}/home';
    final data = '$home/Library/Containers/${SandboxMigration.bundleId}/Data';
    final containerLib = '$data/Documents/SnipSnap';
    Directory('$containerLib/Captures').createSync(recursive: true);
    File('$containerLib/Captures/snap_1.png').writeAsStringSync('pixels');
    final dbPath = createDb('$containerLib/snipsnap_local.sqlite');
    insertCapture(dbPath, 'cap1', '$containerLib/Captures/snap_1.png');

    await SandboxMigration.runIfNeeded(homeOverride: home);

    expect(captureRows('$home/Documents/SnipSnap/snipsnap_local.sqlite'), [
      {
        'id': 'cap1',
        'file_path': '$home/Documents/SnipSnap/Captures/snap_1.png',
      },
    ]);
    // The container database itself is never touched.
    expect(captureRows(dbPath), [
      {'id': 'cap1', 'file_path': '$containerLib/Captures/snap_1.png'},
    ]);
  });
}
