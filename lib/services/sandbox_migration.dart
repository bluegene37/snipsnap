import 'dart:io';

import 'package:flutter/foundation.dart';

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
    } catch (e) {
      // A failed copy must never block startup; the sandboxed data is still
      // in the container, untouched, for a retry on the next launch.
      debugPrint('SandboxMigration: failed, will retry next launch: $e');
    }
  }
}
