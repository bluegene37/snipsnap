import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:snipsnap/services/update/update_info.dart';
import 'package:snipsnap/services/update/update_service.dart';

Map<String, dynamic> release(String tag) => {
  'tag_name': tag,
  'html_url': 'https://github.com/bluegene37/snipsnap/releases/tag/$tag',
  'assets': [
    {
      'name': 'Snipsnap-x86_64-Installer.exe',
      'browser_download_url': 'https://example.com/installer.exe',
      'size': 10,
    },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late int fetchCalls;

  UpdateService service({
    String latestTag = 'v1.1.0',
    String currentVersion = '1.0.0',
    DateTime? now,
    Object? fetchError,
  }) {
    return UpdateService(
      currentVersion: currentVersion,
      platform: UpdatePlatform.windows,
      now: () => now ?? DateTime(2026, 8, 28, 12),
      fetchRelease: (_) async {
        fetchCalls++;
        if (fetchError != null) throw fetchError;
        return release(latestTag);
      },
    );
  }

  setUp(() {
    fetchCalls = 0;
    SharedPreferences.setMockInitialValues({});
  });

  test('feed URL is this repo\'s latest-release endpoint', () {
    expect(
      UpdateService.latestReleaseUrl.toString(),
      'https://api.github.com/repos/bluegene37/snipsnap/releases/latest',
    );
  });

  group('checkForUpdate', () {
    test('reports available when a newer release exists', () async {
      final result = await service().checkForUpdate();
      expect(result.status, UpdateStatus.available);
      expect(result.info!.version.toString(), '1.1.0');
      expect(fetchCalls, 1);
    });

    test('reports upToDate when latest equals current', () async {
      final result = await service(latestTag: 'v1.0.0').checkForUpdate();
      expect(result.status, UpdateStatus.upToDate);
    });

    test('reports upToDate when latest is older than current', () async {
      final result = await service(
        latestTag: 'v1.0.0',
        currentVersion: '2.0.0',
      ).checkForUpdate();
      expect(result.status, UpdateStatus.upToDate);
    });

    test('throttles network calls within the check interval', () async {
      await service().checkForUpdate();
      expect(fetchCalls, 1);

      // Second check 1 hour later: no network call, but the cached release
      // still surfaces the available update (app-restart survival).
      final result = await service(
        now: DateTime(2026, 8, 28, 13),
      ).checkForUpdate();
      expect(fetchCalls, 1);
      expect(result.status, UpdateStatus.available);
      expect(result.info!.version.toString(), '1.1.0');
    });

    test('checks the network again after the interval elapses', () async {
      await service().checkForUpdate();
      await service(now: DateTime(2026, 8, 29, 13)).checkForUpdate();
      expect(fetchCalls, 2);
    });

    test('force bypasses the throttle', () async {
      await service().checkForUpdate();
      await service().checkForUpdate(force: true);
      expect(fetchCalls, 2);
    });

    test('a failed fetch stores no cache or timestamp', () async {
      final failed = await service(
        fetchError: const SocketException('offline'),
      ).checkForUpdate();
      expect(failed.status, UpdateStatus.failed);

      // Within the interval, but the failed attempt must not have started
      // the throttle window — the next check hits the network again.
      await service().checkForUpdate();
      expect(fetchCalls, 2);
    });

    test('a skipped version is reported as skipped, not available', () async {
      final s = service();
      final first = await s.checkForUpdate();
      await s.skipVersion(first.info!.version);

      final result = await s.checkForUpdate(force: true);
      expect(result.status, UpdateStatus.skipped);
    });

    test('a release newer than the skipped one is available again', () async {
      final s = service();
      final first = await s.checkForUpdate();
      await s.skipVersion(first.info!.version);

      final result = await service(
        latestTag: 'v1.2.0',
      ).checkForUpdate(force: true);
      expect(result.status, UpdateStatus.available);
    });

    test(
      'ignoreSkipped surfaces a skipped version as available again',
      () async {
        // A manual "Check for updates" should always show what exists.
        final s = service();
        final first = await s.checkForUpdate();
        await s.skipVersion(first.info!.version);

        final result = await s.checkForUpdate(force: true, ignoreSkipped: true);
        expect(result.status, UpdateStatus.available);
      },
    );

    test('network failure yields failed result without throwing', () async {
      final result = await service(
        fetchError: const SocketException('offline'),
      ).checkForUpdate();
      expect(result.status, UpdateStatus.failed);
      expect(result.error, isA<SocketException>());
    });

    test('unparseable release tag yields failed result', () async {
      final result = await service(latestTag: 'nightly').checkForUpdate();
      expect(result.status, UpdateStatus.failed);
    });
  });

  group('real HTTP (loopback)', () {
    setUpAll(() {
      // The flutter_test binding replaces HttpClient with a stub that always
      // returns 400. These tests exercise the real client against a local
      // loopback server, so restore real networking for this group.
      HttpOverrides.global = null;
    });

    test(
      'default fetcher sends GitHub Accept and User-Agent headers',
      () async {
        late HttpHeaders seenHeaders;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((req) {
          seenHeaders = req.headers;
          req.response
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(release('v9.9.9')));
          req.response.close();
        });
        addTearDown(() => server.close(force: true));

        final json = await UpdateService.fetchReleaseHttp(
          Uri.parse('http://127.0.0.1:${server.port}/latest'),
        );
        expect(json['tag_name'], 'v9.9.9');
        expect(seenHeaders.value('accept'), 'application/vnd.github+json');
        expect(seenHeaders.value('user-agent'), contains('SnipSnap'));
      },
    );

    test('downloads bytes to a file and verifies the size', () async {
      final bytes = List<int>.generate(1024, (i) => i % 256);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) {
        req.response
          ..headers.contentType = ContentType.binary
          ..add(bytes);
        req.response.close();
      });
      addTearDown(() => server.close(force: true));

      final dir = Directory.systemTemp.createTempSync('upd_test_');
      addTearDown(() => dir.deleteSync(recursive: true));

      var lastReceived = 0;
      var lastTotal = 0;
      final asset = UpdateAsset(
        name: 'installer.exe',
        downloadUrl: 'http://127.0.0.1:${server.port}/installer.exe',
        size: bytes.length,
      );

      final file = await UpdateService.downloadAsset(
        asset,
        dir: dir,
        onProgress: (received, total) {
          lastReceived = received;
          lastTotal = total;
        },
      );
      expect(file.existsSync(), isTrue);
      expect(file.lengthSync(), bytes.length);
      expect(lastReceived, bytes.length);
      expect(lastTotal, bytes.length);
    });

    test('deletes the partial file and throws on a size mismatch', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) {
        req.response.add([1, 2, 3]);
        req.response.close();
      });
      addTearDown(() => server.close(force: true));

      final dir = Directory.systemTemp.createTempSync('upd_test_');
      addTearDown(() => dir.deleteSync(recursive: true));

      final asset = UpdateAsset(
        name: 'installer.exe',
        downloadUrl: 'http://127.0.0.1:${server.port}/installer.exe',
        size: 999,
      );

      await expectLater(
        UpdateService.downloadAsset(asset, dir: dir),
        throwsA(isA<StateError>()),
      );
      expect(File('${dir.path}/installer.exe').existsSync(), isFalse);
    });
  });

  group('windows install script', () {
    test('quotes paths, installs silently, relaunches, self-deletes', () {
      final script = UpdateService.buildWindowsInstallScript(
        installerPath: r'C:\Users\Jo Doe\AppData\Local\Temp\inst.exe',
        appExePath: r'C:\Program Files\SnipSnap\snipsnap.exe',
      );
      expect(script, startsWith('@echo off\r\n'));
      expect(
        script,
        contains('"C:\\Users\\Jo Doe\\AppData\\Local\\Temp\\inst.exe"'),
      );
      expect(script, contains('/SILENT'));
      expect(script, contains('/CLOSEAPPLICATIONS'));
      expect(script, contains('/NORESTART'));
      expect(script, contains('del "%~f0"'));
      // Every line CRLF-terminated.
      expect(script.split('\r\n').where((l) => l.contains('\n')), isEmpty);
      // Relaunch line must come after the installer invocation.
      final installIdx = script.indexOf('inst.exe');
      final relaunchIdx = script.indexOf('snipsnap.exe');
      expect(relaunchIdx, greaterThan(installIdx));
    });
  });

  group('macos install script', () {
    final script = UpdateService.buildMacosInstallScript();

    test('is fixed text — no caller path ever appears in the source', () {
      // Paths reach the script as positional args, so a dollar, backtick, or
      // quote in a file name can never break or retarget it. The script must
      // therefore reference them exclusively through its own variables.
      expect(script, contains(r'DMG="$1"'));
      expect(script, contains(r'APP="$2"'));
      expect(script, contains(r'WORK="$3"'));
      expect(script, contains(r'APP_PID="$4"'));
    });

    test('bounds the wait for the app to exit', () {
      // A recycled pid must not wedge the script forever.
      final waitIdx = script.indexOf(r'kill -0 "$APP_PID"');
      expect(waitIdx, greaterThanOrEqualTo(0));
      expect(waitIdx, lessThan(script.indexOf('hdiutil attach')));
      expect(script, contains('-ge 150'));
    });

    test('swaps by rename-aside, never by deleting the install first', () {
      // Order: stage the new bundle, move the old one aside, move the staged
      // one in, and only then delete the old — with a rollback if the swap
      // half-happened. No `rm -rf` of the live bundle anywhere.
      final stageIdx = script.indexOf(r'ditto "$SRC" "$STAGED"');
      final asideIdx = script.indexOf(r'mv "$APP" "$OLD"');
      final swapIdx = script.indexOf(r'mv "$STAGED" "$APP"');
      final reapIdx = script.indexOf(r'rm -rf "$OLD"');
      expect(stageIdx, greaterThanOrEqualTo(0));
      expect(asideIdx, greaterThan(stageIdx));
      expect(swapIdx, greaterThan(asideIdx));
      expect(reapIdx, greaterThan(swapIdx));
      expect(script, contains(r'mv "$OLD" "$APP"'), reason: 'rollback line');
      expect(script, isNot(contains(r'rm -rf "$APP"')));
    });

    test('stages next to the target so the swap moves are same-volume', () {
      expect(script, contains(r'STAGED="$PARENT/'));
      expect(script, contains(r'OLD="$PARENT/'));
    });

    test('picks the DMG bundle by the installed name, not sort order', () {
      expect(script, contains(r'SRC="$MOUNT/$(/usr/bin/basename "$APP")"'));
    });

    test('relaunches and cleans up on every path, mount failure included', () {
      // `open` must sit outside the attach branch, after it, and the work-dir
      // cleanup must be gated on the image being unmounted.
      final detachIdx = script.indexOf('hdiutil detach');
      final openIdx = script.indexOf(r'open "$APP"');
      final guardIdx = script.indexOf(r'grep -qF "$MOUNT"');
      final cleanupIdx = script.indexOf(r'rm -rf "$WORK"');
      expect(openIdx, greaterThan(detachIdx));
      expect(guardIdx, greaterThan(openIdx));
      expect(cleanupIdx, greaterThan(guardIdx));
    });

    test('parses as valid shell', () async {
      final dir = Directory.systemTemp.createTempSync('upd_sh_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File('${dir.path}/install_update.sh')
        ..writeAsStringSync(script);
      final result = await Process.run('/bin/sh', ['-n', f.path]);
      expect(result.exitCode, 0, reason: 'sh -n rejected: ${result.stderr}');
    }, testOn: 'mac-os');
  });

  group('ensureSwappableBundle', () {
    test('rejects an app running straight off the mounted DMG', () {
      expect(
        () => UpdateService.ensureSwappableBundle('/Volumes/SnipSnap/S.app'),
        throwsStateError,
      );
    });

    test('rejects a Gatekeeper-translocated copy', () {
      expect(
        () => UpdateService.ensureSwappableBundle(
          '/private/var/folders/ab/x/T/AppTranslocation/uuid/d/S.app',
        ),
        throwsStateError,
      );
    });

    test('rejects a bundle whose parent directory is not writable', () {
      final dir = Directory.systemTemp.createTempSync('upd_ro_');
      addTearDown(() {
        Process.runSync('chmod', ['755', dir.path]);
        dir.deleteSync(recursive: true);
      });
      final bundle = Directory('${dir.path}/S.app')..createSync();
      Process.runSync('chmod', ['555', dir.path]);
      expect(
        () => UpdateService.ensureSwappableBundle(bundle.path),
        throwsStateError,
      );
    }, testOn: 'mac-os');

    test('accepts a bundle in a writable directory', () {
      final dir = Directory.systemTemp.createTempSync('upd_rw_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final bundle = Directory('${dir.path}/S.app')..createSync();
      expect(
        () => UpdateService.ensureSwappableBundle(bundle.path),
        returnsNormally,
      );
    });
  });

  group('macosAppBundlePath', () {
    test('resolves the bundle root from the executable inside it', () {
      expect(
        UpdateService.macosAppBundlePath(
          '/Applications/Snip Snap.app/Contents/MacOS/snipsnap',
        ),
        '/Applications/Snip Snap.app',
      );
    });

    test('throws when the executable is not inside a bundle', () {
      expect(
        () => UpdateService.macosAppBundlePath('/usr/local/bin/snipsnap'),
        throwsStateError,
      );
    });
  });

  group('openUrlCommand', () {
    test('uses the platform launcher for the release page', () {
      expect(UpdateService.openUrlCommand(UpdatePlatform.macos, 'https://x'), [
        'open',
        'https://x',
      ]);
      expect(UpdateService.openUrlCommand(UpdatePlatform.linux, 'https://x'), [
        'xdg-open',
        'https://x',
      ]);
      expect(
        UpdateService.openUrlCommand(UpdatePlatform.windows, 'https://x'),
        ['cmd.exe', '/c', 'start', '', 'https://x'],
      );
    });
  });
}
