import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

/// One-time move of user data out of the macOS App Sandbox container.
///
/// Releases up to and including 1.0.2 shipped sandboxed, so everything the
/// app stores — the capture database and images under `Documents/SnipSnap`,
/// plus `SharedPreferences` — lives inside
/// `~/Library/Containers/<bundle id>/Data`. The sandbox was dropped to make
/// the in-app updater possible (mounting a DMG and replacing the bundle are
/// both denied from inside it), which silently changes where every one of
/// those paths resolves. Without this shim, the first unsandboxed launch
/// would come up with an empty library and default settings while the user's
/// real data sat stranded in the container.
///
/// Runs before the database or preferences are first touched, and only acts
/// when the destination does not exist yet — an already-migrated (or fresh)
/// install is a no-op, and nothing is ever overwritten or deleted. The
/// container copy is left in place as a safety net.
class SandboxMigration {
  SandboxMigration._();

  /// The macOS bundle identifier — must match `PRODUCT_BUNDLE_IDENTIFIER` in
  /// `macos/Runner/Configs/AppInfo.xcconfig`; it names the old container.
  static const String bundleId = 'dev.genexis.snipsnap';

  /// Copies [from] into [to] recursively. Only acts when [from] exists and
  /// [to] does not; returns whether a copy happened. Never deletes [from].
  @visibleForTesting
  static Future<bool> migrateTree(Directory from, Directory to) async {
    if (!from.existsSync() || to.existsSync()) return false;
    await to.create(recursive: true);
    await for (final entity in from.list(recursive: true)) {
      final relative = entity.path.substring(from.path.length + 1);
      final target = '${to.path}/$relative';
      if (entity is Directory) {
        await Directory(target).create(recursive: true);
      } else if (entity is File) {
        await entity.copy(target);
      }
    }
    return true;
  }

  /// Copies the sandboxed preferences plist to the unsandboxed location so
  /// settings, shortcuts, and updater state survive. Best-effort and only
  /// when no unsandboxed plist exists yet; must run before anything reads
  /// `SharedPreferences`, or `cfprefsd` will have cached the empty domain.
  @visibleForTesting
  static Future<bool> migratePrefs(File from, File to) async {
    if (!from.existsSync() || to.existsSync()) return false;
    await to.parent.create(recursive: true);
    await from.copy(to.path);
    return true;
  }

  /// Repairs capture rows that still point into the old sandbox container.
  ///
  /// The tree copy above duplicates `snipsnap_local.sqlite` byte-for-byte, so
  /// every `captures.file_path` inside it still names the container file.
  /// Left alone, two things go wrong on the very next launch: the library
  /// scan in `StorageService.loadHistory` re-registers the migrated copy as a
  /// brand-new capture (every capture shows up twice in the gallery), and
  /// edits made through the original row keep writing into the container the
  /// migration was supposed to abandon, so the two copies silently diverge.
  ///
  /// For each row under [oldRoot]:
  ///  * the container file's bytes win when they are newer than the migrated
  ///    copy — they carry post-migration edits the copy is missing,
  ///  * a duplicate row the library scan created for the migrated path is
  ///    deleted, but only when it has no annotations of its own; a twin with
  ///    annotations is a genuine fork and both rows are left untouched,
  ///  * the row's path is rewritten from [oldRoot] to [newRoot], and
  ///  * `active_capture_id` follows a deleted twin to the surviving row.
  ///
  /// Idempotent and cheap: once no row points into the container the SELECT
  /// matches nothing. Every error is logged and swallowed — startup must
  /// never block on repair, and the container copy stays as the safety net.
  @visibleForTesting
  static void repairCapturePaths({
    required String dbPath,
    required String oldRoot,
    required String newRoot,
  }) {
    if (!File(dbPath).existsSync()) return;
    sql.Database? db;
    try {
      db = sql.sqlite3.open(dbPath);
      final hasCaptures = db
          .select(
            "SELECT name FROM sqlite_master "
            "WHERE type = 'table' AND name = 'captures'",
          )
          .isNotEmpty;
      if (!hasCaptures) return;

      final prefix = '$oldRoot/';
      final rows = db.select(
        'SELECT id, file_path FROM captures WHERE substr(file_path, 1, ?) = ?',
        [prefix.length, prefix],
      );
      for (final row in rows) {
        final id = row['id'] as String;
        final oldPath = row['file_path'] as String;
        final newPath = '$newRoot/${oldPath.substring(prefix.length)}';

        final twins = db.select(
          'SELECT id FROM captures WHERE file_path = ? AND id != ?',
          [newPath, id],
        );
        var fork = false;
        for (final twin in twins) {
          final twinId = twin['id'] as String;
          final annotated =
              db.select(
                    'SELECT COUNT(*) AS n FROM annotations '
                    'WHERE capture_id = ?',
                    [twinId],
                  ).first['n']
                  as int;
          if (annotated > 0) {
            // The duplicate carries its own markup: a real fork. Deleting or
            // re-pointing either side would destroy user work, so keep both.
            debugPrint(
              'SandboxMigration: capture $id has an annotated duplicate '
              '$twinId; leaving both untouched',
            );
            fork = true;
            continue;
          }
          db.execute('DELETE FROM annotations WHERE capture_id = ?', [twinId]);
          db.execute('DELETE FROM captures WHERE id = ?', [twinId]);
          db.execute(
            'UPDATE app_settings SET value = ? '
            "WHERE key = 'active_capture_id' AND value = ?",
            [id, twinId],
          );
        }
        if (fork) continue;

        // The container file was the live edit target until this repair ran,
        // so newer bytes there carry edits the migrated copy is missing.
        final oldFile = File(oldPath);
        final newFile = File(newPath);
        if (oldFile.existsSync()) {
          final copyIsStale =
              !newFile.existsSync() ||
              oldFile.statSync().modified.isAfter(newFile.statSync().modified);
          if (copyIsStale) {
            newFile.parent.createSync(recursive: true);
            oldFile.copySync(newPath);
          }
        }

        db.execute('UPDATE captures SET file_path = ? WHERE id = ?', [
          newPath,
          id,
        ]);
      }
    } catch (e) {
      debugPrint('SandboxMigration: path repair failed: $e');
    } finally {
      db?.close();
    }
  }

  /// Entry point called from `main()`. No-op everywhere except an
  /// unsandboxed macOS run that still has a populated container.
  static Future<void> runIfNeeded({String? homeOverride}) async {
    if (!Platform.isMacOS && homeOverride == null) return;
    final home = homeOverride ?? Platform.environment['HOME'];
    if (home == null) return;
    // A sandboxed build sees the container itself as $HOME — in that world
    // the paths below would self-reference. Nothing to migrate from inside.
    if (home.contains('/Library/Containers/')) return;

    final containerData = '$home/Library/Containers/$bundleId/Data';
    try {
      final movedData = await migrateTree(
        Directory('$containerData/Documents/SnipSnap'),
        Directory('$home/Documents/SnipSnap'),
      );
      final movedPrefs = await migratePrefs(
        File('$containerData/Library/Preferences/$bundleId.plist'),
        File('$home/Library/Preferences/$bundleId.plist'),
      );
      if (movedData || movedPrefs) {
        debugPrint(
          'SandboxMigration: copied sandbox container data '
          '(library: $movedData, prefs: $movedPrefs)',
        );
      }
      // The copied database still points every capture into the container.
      // Repair runs on every launch that still has a container library (a
      // no-op once clean), so installs that migrated before this fix existed
      // are healed too, not just fresh migrations.
      if (Directory('$containerData/Documents/SnipSnap').existsSync()) {
        repairCapturePaths(
          dbPath: '$home/Documents/SnipSnap/snipsnap_local.sqlite',
          oldRoot: '$containerData/Documents/SnipSnap',
          newRoot: '$home/Documents/SnipSnap',
        );
      }
    } catch (e) {
      // A failed copy must never block startup; the sandboxed data is still
      // in the container, untouched, for a retry on the next launch.
      debugPrint('SandboxMigration: failed, will retry next launch: $e');
    }
  }
}
