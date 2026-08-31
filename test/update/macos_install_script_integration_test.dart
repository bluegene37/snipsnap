@TestOn('mac-os')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/services/update/update_service.dart';

/// Runs the generated swap script against real DMGs built with `hdiutil` —
/// the same tool chain the updater uses in production. Everything lives in
/// temp directories; the only global touched is a mount point the script
/// itself detaches.
///
/// The script takes its paths as positional args (dmg, app bundle, work dir,
/// app pid), exactly as `downloadAndInstallMacos` passes them.
Future<ProcessResult> _runSwap({
  required String dmgPath,
  required String appPath,
  required String workDir,
}) async {
  // A pid that is already gone, so the script's wait loop exits at once.
  final ephemeral = await Process.start('/usr/bin/true', const []);
  await ephemeral.exitCode;

  final script = File('$workDir/install_update.sh')
    ..writeAsStringSync(UpdateService.buildMacosInstallScript());
  return Process.run('/bin/sh', [
    script.path,
    dmgPath,
    appPath,
    workDir,
    '${ephemeral.pid}',
  ]);
}

Future<void> _makeDmg(String srcFolder, String dmgPath) async {
  final create = await Process.run('/usr/bin/hdiutil', [
    'create',
    '-srcfolder',
    srcFolder,
    '-volname',
    'SnipSnap Update Test',
    '-format',
    'UDZO',
    '-quiet',
    dmgPath,
  ]);
  expect(create.exitCode, 0, reason: 'hdiutil create: ${create.stderr}');
}

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('snipsnap_swap_'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Directory installApp(String marker, {String name = 'Snip Snap.app'}) {
    final app = Directory('${root.path}/Applications/$name')
      ..createSync(recursive: true);
    File('${app.path}/marker.txt').writeAsStringSync(marker);
    return app;
  }

  Future<String> releaseDmg(
    String marker, {
    String name = 'Snip Snap.app',
  }) async {
    final payload = Directory('${root.path}/payload/$name')
      ..createSync(recursive: true);
    File('${payload.path}/marker.txt').writeAsStringSync(marker);
    final dmgPath = '${root.path}/work/snipsnap-update.dmg';
    Directory('${root.path}/work').createSync(recursive: true);
    await _makeDmg('${root.path}/payload', dmgPath);
    return dmgPath;
  }

  test(
    'the swap script replaces the installed bundle with the DMG one',
    () async {
      final installed = installApp('old');
      final dmgPath = await releaseDmg('new');

      final run = await _runSwap(
        dmgPath: dmgPath,
        appPath: installed.path,
        workDir: '${root.path}/work',
      );

      expect(run.exitCode, 0, reason: 'script stderr: ${run.stderr}');
      expect(File('${installed.path}/marker.txt').readAsStringSync(), 'new');
      expect(
        Directory('${root.path}/work').existsSync(),
        isFalse,
        reason: 'the DMG must be detached and the work dir cleaned up',
      );
      expect(
        Directory(
          '${root.path}/Applications',
        ).listSync().map((e) => e.path.split('/').last),
        ['Snip Snap.app'],
        reason: 'no staging or aside bundles may be left behind',
      );
    },
  );

  test(
    'a bad DMG leaves the installed bundle untouched and cleans up',
    () async {
      final installed = installApp('old');
      final workDir = '${root.path}/work';
      Directory(workDir).createSync(recursive: true);
      // Garbage bytes: hdiutil attach must fail, and the script must bail.
      final dmgPath = '$workDir/broken.dmg';
      File(dmgPath).writeAsBytesSync(List.filled(64, 7));

      final run = await _runSwap(
        dmgPath: dmgPath,
        appPath: installed.path,
        workDir: workDir,
      );

      expect(run.exitCode, isNot(0), reason: 'the script must report failure');
      expect(File('${installed.path}/marker.txt').readAsStringSync(), 'old');
      expect(
        Directory(workDir).existsSync(),
        isFalse,
        reason: 'even the failure path must not strand the downloaded DMG',
      );
    },
  );

  test('a locked file in the old bundle cannot gut the install', () async {
    // The regression this design exists to prevent: a delete-first swap hits
    // an unlinkable file mid-`rm -rf`, destroys every sibling it can, and
    // then deletes the staged copy too — no app left. Rename-aside moves the
    // old bundle out whole, so a lock inside it is harmless.
    final installed = installApp('old');
    final locked = File('${installed.path}/locked.txt')..writeAsStringSync('x');
    await Process.run('/usr/bin/chflags', ['uchg', locked.path]);
    addTearDown(() async {
      // Unlock whatever survives so tearDown can delete the tree.
      await Process.run('/usr/bin/chflags', ['-R', 'nouchg', root.path]);
    });
    final dmgPath = await releaseDmg('new');

    final run = await _runSwap(
      dmgPath: dmgPath,
      appPath: installed.path,
      workDir: '${root.path}/work',
    );

    expect(run.exitCode, 0, reason: 'script stderr: ${run.stderr}');
    expect(
      File('${installed.path}/marker.txt').readAsStringSync(),
      'new',
      reason: 'the new bundle must be installed despite the locked old file',
    );
  });

  test('paths with shell metacharacters are handled verbatim', () async {
    // $, quotes, and spaces in an install path travel as argv, never through
    // script-source interpolation — so none of them can retarget the swap.
    final installed = installApp('old', name: r'Snip $HOME "v2".app');
    final dmgPath = await releaseDmg('new', name: r'Snip $HOME "v2".app');

    final run = await _runSwap(
      dmgPath: dmgPath,
      appPath: installed.path,
      workDir: '${root.path}/work',
    );

    expect(run.exitCode, 0, reason: 'script stderr: ${run.stderr}');
    expect(File('${installed.path}/marker.txt').readAsStringSync(), 'new');
  });

  test('a renamed install still updates from the DMG single bundle', () async {
    // The exact-name match misses, so the script falls back to the DMG's
    // only .app — but never to "whichever sorts first" among several.
    final installed = installApp('old', name: 'My Renamed Snip.app');
    final dmgPath = await releaseDmg('new'); // ships as "Snip Snap.app"

    final run = await _runSwap(
      dmgPath: dmgPath,
      appPath: installed.path,
      workDir: '${root.path}/work',
    );

    expect(run.exitCode, 0, reason: 'script stderr: ${run.stderr}');
    expect(File('${installed.path}/marker.txt').readAsStringSync(), 'new');
  });
}
