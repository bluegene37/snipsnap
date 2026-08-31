import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/services/sandbox_migration.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('snipsnap_mig_'));
  tearDown(() => root.deleteSync(recursive: true));

  group('migrateTree', () {
    test('copies the tree when the destination does not exist', () async {
      final from = Directory('${root.path}/from')..createSync();
      Directory('${from.path}/Captures').createSync();
      File('${from.path}/snipsnap_local.sqlite').writeAsStringSync('db');
      File('${from.path}/Captures/cap1.png').writeAsStringSync('img');
      final to = Directory('${root.path}/to');

      expect(await SandboxMigration.migrateTree(from, to), isTrue);
      expect(File('${to.path}/snipsnap_local.sqlite').readAsStringSync(), 'db');
      expect(File('${to.path}/Captures/cap1.png').readAsStringSync(), 'img');
      // The source is a safety net, never deleted.
      expect(from.existsSync(), isTrue);
    });

    test('never touches an existing destination', () async {
      final from = Directory('${root.path}/from')..createSync();
      File('${from.path}/snipsnap_local.sqlite').writeAsStringSync('old');
      final to = Directory('${root.path}/to')..createSync();
      File('${to.path}/snipsnap_local.sqlite').writeAsStringSync('current');

      expect(await SandboxMigration.migrateTree(from, to), isFalse);
      expect(
        File('${to.path}/snipsnap_local.sqlite').readAsStringSync(),
        'current',
      );
    });

    test('no-op when the source does not exist', () async {
      final to = Directory('${root.path}/to');
      expect(
        await SandboxMigration.migrateTree(
          Directory('${root.path}/missing'),
          to,
        ),
        isFalse,
      );
      expect(to.existsSync(), isFalse);
    });
  });

  group('migratePrefs', () {
    test('copies the plist only when none exists at the destination', () async {
      final from = File('${root.path}/old.plist')..writeAsStringSync('prefs');
      final to = File('${root.path}/nested/new.plist');

      expect(await SandboxMigration.migratePrefs(from, to), isTrue);
      expect(to.readAsStringSync(), 'prefs');

      from.writeAsStringSync('changed');
      expect(await SandboxMigration.migratePrefs(from, to), isFalse);
      expect(to.readAsStringSync(), 'prefs');
    });
  });

  group('runIfNeeded', () {
    test('moves container data and prefs into an unsandboxed home', () async {
      final home = '${root.path}/home';
      final data = '$home/Library/Containers/${SandboxMigration.bundleId}/Data';
      Directory(
        '$data/Documents/SnipSnap/Captures',
      ).createSync(recursive: true);
      File(
        '$data/Documents/SnipSnap/snipsnap_local.sqlite',
      ).writeAsStringSync('db');
      Directory('$data/Library/Preferences').createSync(recursive: true);
      File(
        '$data/Library/Preferences/${SandboxMigration.bundleId}.plist',
      ).writeAsStringSync('prefs');

      await SandboxMigration.runIfNeeded(homeOverride: home);

      expect(
        File(
          '$home/Documents/SnipSnap/snipsnap_local.sqlite',
        ).readAsStringSync(),
        'db',
      );
      expect(
        File(
          '$home/Library/Preferences/${SandboxMigration.bundleId}.plist',
        ).readAsStringSync(),
        'prefs',
      );
    });

    test('does nothing when running inside a sandbox container', () async {
      // A sandboxed build sees the container as $HOME; migrating from there
      // would self-reference.
      final home =
          '${root.path}/Library/Containers/${SandboxMigration.bundleId}/Data';
      Directory(home).createSync(recursive: true);
      await SandboxMigration.runIfNeeded(homeOverride: home);
      expect(Directory('$home/Documents').existsSync(), isFalse);
    });

    test('is idempotent — a second run changes nothing', () async {
      final home = '${root.path}/home';
      final data = '$home/Library/Containers/${SandboxMigration.bundleId}/Data';
      Directory('$data/Documents/SnipSnap').createSync(recursive: true);
      File(
        '$data/Documents/SnipSnap/snipsnap_local.sqlite',
      ).writeAsStringSync('db');

      await SandboxMigration.runIfNeeded(homeOverride: home);
      // The user now works in the migrated copy...
      File(
        '$home/Documents/SnipSnap/snipsnap_local.sqlite',
      ).writeAsStringSync('db+new-captures');
      // ...and a relaunch must not clobber it with the stale container copy.
      await SandboxMigration.runIfNeeded(homeOverride: home);

      expect(
        File(
          '$home/Documents/SnipSnap/snipsnap_local.sqlite',
        ).readAsStringSync(),
        'db+new-captures',
      );
    });
  });
}
