import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app_info.dart';
import 'semver.dart';
import 'update_info.dart';

/// How the latest-release payload is fetched. Injectable so tests never
/// touch the network.
typedef ReleaseFetcher = Future<Map<String, dynamic>> Function(Uri url);

enum UpdateStatus { upToDate, available, skipped, failed }

class UpdateCheckResult {
  const UpdateCheckResult(this.status, {this.info, this.error});

  final UpdateStatus status;
  final UpdateInfo? info;
  final Object? error;
}

/// Checks GitHub Releases for a newer version and hands off installation.
///
/// State (last check time, cached release, skipped version) lives in
/// [SharedPreferences] because it is app-global; the Drift capture database
/// holds live user data and must not grow updater keys.
class UpdateService {
  UpdateService({
    String? currentVersion,
    UpdatePlatform? platform,
    ReleaseFetcher? fetchRelease,
    DateTime Function()? now,
    this.checkInterval = const Duration(hours: 24),
  }) : currentVersion = Semver.parse(currentVersion ?? AppInfo.appVersion),
       platform = platform ?? _currentPlatform(),
       _fetchRelease = fetchRelease ?? fetchReleaseHttp,
       _now = now ?? DateTime.now;

  static const String repoSlug = 'bluegene37/snipsnap';
  static final Uri latestReleaseUrl = Uri.parse(
    'https://api.github.com/repos/$repoSlug/releases/latest',
  );

  static const String _lastCheckKey = 'update_last_check_epoch_ms';
  static const String _cachedReleaseKey = 'update_cached_release_json';
  static const String _skippedVersionKey = 'update_skipped_version';

  final Semver currentVersion;
  final UpdatePlatform platform;
  final Duration checkInterval;
  final ReleaseFetcher _fetchRelease;
  final DateTime Function() _now;

  static UpdatePlatform _currentPlatform() {
    if (Platform.isWindows) return UpdatePlatform.windows;
    if (Platform.isMacOS) return UpdatePlatform.macos;
    return UpdatePlatform.linux;
  }

  /// Checks whether a newer release exists. Never throws — every failure
  /// (network, parse, even unavailable prefs) becomes a
  /// [UpdateStatus.failed] result.
  ///
  /// Network calls are throttled to one per [checkInterval]; inside the
  /// window the last fetched release (cached in prefs) is re-evaluated so a
  /// pending update still surfaces after an app restart. [force] bypasses
  /// the throttle; [ignoreSkipped] additionally resurfaces a version the
  /// user chose to skip (for a manual "Check for updates").
  Future<UpdateCheckResult> checkForUpdate({
    bool force = false,
    bool ignoreSkipped = false,
  }) async {
    try {
      return await _checkForUpdate(force: force, ignoreSkipped: ignoreSkipped);
    } catch (e) {
      debugPrint('UpdateService: check failed: $e');
      return UpdateCheckResult(UpdateStatus.failed, error: e);
    }
  }

  Future<UpdateCheckResult> _checkForUpdate({
    required bool force,
    required bool ignoreSkipped,
  }) async {
    final prefs = await SharedPreferences.getInstance();

    Map<String, dynamic>? releaseJson;
    final lastCheckMs = prefs.getInt(_lastCheckKey);
    final withinWindow =
        lastCheckMs != null &&
        _now().difference(DateTime.fromMillisecondsSinceEpoch(lastCheckMs)) <
            checkInterval;

    if (!force && withinWindow) {
      final cached = prefs.getString(_cachedReleaseKey);
      if (cached == null) return const UpdateCheckResult(UpdateStatus.upToDate);
      releaseJson = jsonDecode(cached) as Map<String, dynamic>;
    } else {
      try {
        releaseJson = await _fetchRelease(latestReleaseUrl);
      } catch (e) {
        debugPrint('UpdateService: fetch failed: $e');
        return UpdateCheckResult(UpdateStatus.failed, error: e);
      }
      // Cache + timestamp only after a successful fetch, so a failed
      // attempt never starts the throttle window.
      await prefs.setString(_cachedReleaseKey, jsonEncode(releaseJson));
      await prefs.setInt(_lastCheckKey, _now().millisecondsSinceEpoch);
    }

    final info = UpdateInfo.tryFromReleaseJson(releaseJson, platform);
    if (info == null) {
      return UpdateCheckResult(
        UpdateStatus.failed,
        error: FormatException(
          'Latest release tag is not a version: ${releaseJson['tag_name']}',
        ),
      );
    }

    if (!info.version.isNewerThan(currentVersion)) {
      return UpdateCheckResult(UpdateStatus.upToDate, info: info);
    }
    if (!ignoreSkipped &&
        prefs.getString(_skippedVersionKey) == info.version.toString()) {
      return UpdateCheckResult(UpdateStatus.skipped, info: info);
    }
    return UpdateCheckResult(UpdateStatus.available, info: info);
  }

  /// Records that the user does not want to hear about [version] again.
  Future<void> skipVersion(Semver version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_skippedVersionKey, version.toString());
  }

  /// Production fetcher: GET [url] with the GitHub REST media type and an
  /// identifying User-Agent (GitHub rejects requests without one).
  @visibleForTesting
  static Future<Map<String, dynamic>> fetchReleaseHttp(Uri url) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(url);
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.github+json',
      );
      request.headers.set(
        HttpHeaders.userAgentHeader,
        '${AppInfo.appName}/${AppInfo.appVersion}',
      );
      final response = await request.close();
      final body = await utf8.decodeStream(response);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'GET $url returned ${response.statusCode}',
          uri: url,
        );
      }
      return jsonDecode(body) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  /// Downloads [asset] into [dir] (a fresh temp dir by default) and verifies
  /// the byte count against the size GitHub reported. On a mismatch the
  /// partial file is deleted and a [StateError] is thrown.
  static Future<File> downloadAsset(
    UpdateAsset asset, {
    Directory? dir,
    void Function(int received, int total)? onProgress,
  }) async {
    final targetDir =
        dir ?? await Directory.systemTemp.createTemp('snipsnap_update_');
    // The asset name comes from the release JSON — external input. Flatten
    // any separators so a hostile name cannot climb out of the temp dir.
    final safeName = asset.name.replaceAll(RegExp(r'[/\\]'), '_');
    final file = File('${targetDir.path}${Platform.pathSeparator}$safeName');

    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(asset.downloadUrl));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'GET ${asset.downloadUrl} returned ${response.statusCode}',
        );
      }
      final sink = file.openWrite();
      var received = 0;
      try {
        await for (final chunk in response) {
          received += chunk.length;
          sink.add(chunk);
          onProgress?.call(received, asset.size);
        }
      } finally {
        await sink.close();
      }
      if (asset.size > 0 && received != asset.size) {
        try {
          file.deleteSync();
        } catch (_) {}
        throw StateError(
          'Downloaded ${asset.name} is $received bytes, expected ${asset.size}',
        );
      }
      return file;
    } finally {
      client.close();
    }
  }

  /// Batch script that runs the Inno installer silently, waits for it to
  /// finish, relaunches the app, and deletes itself. Executed detached so it
  /// survives this process exiting (a running exe cannot be overwritten on
  /// Windows — the app must be gone before the installer copies files).
  static String buildWindowsInstallScript({
    required String installerPath,
    required String appExePath,
  }) {
    return '@echo off\r\n'
        'start "" /wait "$installerPath" /SILENT /CLOSEAPPLICATIONS /NORESTART\r\n'
        'start "" "$appExePath"\r\n'
        'del "%~f0"\r\n';
  }

  /// Windows only: downloads the installer, spawns the detached install
  /// script, and exits the app so the installer can replace it.
  /// [Platform.resolvedExecutable] survives the in-place upgrade, so the
  /// script relaunches the new build from the same path.
  Future<void> downloadAndInstallWindows(
    UpdateInfo info, {
    void Function(int received, int total)? onProgress,
    void Function()? exitApp,
  }) async {
    final asset = info.asset;
    if (asset == null) {
      throw StateError('No Windows installer asset on this release');
    }
    final installer = await downloadAsset(asset, onProgress: onProgress);
    final script = File(
      '${installer.parent.path}${Platform.pathSeparator}install_update.bat',
    );
    await script.writeAsString(
      buildWindowsInstallScript(
        installerPath: installer.path,
        appExePath: Platform.resolvedExecutable,
      ),
    );
    await Process.start('cmd.exe', [
      '/c',
      script.path,
    ], mode: ProcessStartMode.detached);
    (exitApp ?? () => exit(0))();
  }

  /// Resolves the `.app` bundle root from an executable path inside it
  /// (`.../SnipSnap.app/Contents/MacOS/snipsnap`). Throws [StateError] when
  /// the executable is not inside a bundle, so a stray dev binary can never
  /// aim the swap script at `/`.
  static String macosAppBundlePath(String executablePath) {
    var dir = File(executablePath).parent;
    while (dir.path != dir.parent.path) {
      if (dir.path.endsWith('.app')) return dir.path;
      dir = dir.parent;
    }
    throw StateError('$executablePath is not inside a .app bundle');
  }

  /// Shell script that waits for the app to exit, mounts the downloaded DMG,
  /// and swaps the new bundle in — the macOS sibling of
  /// [buildWindowsInstallScript]. Executed detached so it survives this
  /// process exiting (the bundle cannot be replaced under a running app).
  ///
  /// The script text is fixed: every path reaches it as a positional
  /// argument (see [downloadAndInstallMacos]), never by interpolation, so a
  /// `$`, backtick, or quote in a file name cannot break or retarget it.
  ///
  /// Safety properties, in order:
  ///
  /// * The wait for the app's pid is bounded (~30s) so a recycled pid cannot
  ///   wedge the script forever.
  /// * The swap is rename-aside, never delete-first: the new bundle is
  ///   staged *next to the target* (same volume, so the moves are atomic
  ///   renames), the old bundle is moved aside, the staged one moved in, and
  ///   only then is the old one deleted. Any failure rolls the old bundle
  ///   back; no path guts the install.
  /// * The staged copy comes from the DMG bundle matching the installed
  ///   app's name, falling back to the image's only `.app` — never
  ///   "whichever sorts first".
  /// * `open` runs on every exit path, mount failure included — the app the
  ///   user had always comes back.
  /// * The work dir (DMG + this script) is deleted only once the image is
  ///   verified unmounted, so a wedged detach leaks instead of recursing
  ///   into a mounted volume.
  ///
  /// Tool paths are absolute: the script runs with whatever environment
  /// `Process.start` inherited, not a login shell.
  static String buildMacosInstallScript() {
    return const [
      r'#!/bin/sh',
      r'# SnipSnap update helper. Args: 1=dmg 2=app bundle 3=work dir 4=app pid.',
      r'DMG="$1"; APP="$2"; WORK="$3"; APP_PID="$4"',
      r'MOUNT="$WORK/mount"',
      r'TRIES=0',
      r'while /bin/kill -0 "$APP_PID" 2>/dev/null; do',
      r'  /bin/sleep 0.2',
      r'  TRIES=$((TRIES + 1))',
      r'  if [ "$TRIES" -ge 150 ]; then break; fi',
      r'done',
      r'STATUS=1',
      r'if /usr/bin/hdiutil attach "$DMG" -nobrowse -noautoopen -mountpoint "$MOUNT"; then',
      r'  PARENT="$(/usr/bin/dirname "$APP")"',
      r'  SRC="$MOUNT/$(/usr/bin/basename "$APP")"',
      r'  if [ ! -d "$SRC" ]; then',
      r'    N=0',
      r'    for CAND in "$MOUNT"/*.app; do',
      r'      if [ -d "$CAND" ]; then SRC="$CAND"; N=$((N + 1)); fi',
      r'    done',
      r'    if [ "$N" -ne 1 ]; then SRC=""; fi',
      r'  fi',
      r'  STAGED="$PARENT/.snipsnap-update-staged.app"',
      r'  OLD="$PARENT/.snipsnap-update-old.app"',
      r'  /bin/rm -rf "$STAGED" "$OLD"',
      r'  if [ -n "$SRC" ] && /usr/bin/ditto "$SRC" "$STAGED"; then',
      r'    if /bin/mv "$APP" "$OLD" && /bin/mv "$STAGED" "$APP"; then',
      r'      /bin/rm -rf "$OLD"',
      r'      STATUS=0',
      r'    else',
      r'      if [ ! -d "$APP" ] && [ -d "$OLD" ]; then /bin/mv "$OLD" "$APP"; fi',
      r'      /bin/rm -rf "$STAGED"',
      r'    fi',
      r'  fi',
      r'  /usr/bin/hdiutil detach "$MOUNT" -force',
      r'fi',
      r'/usr/bin/open "$APP"',
      r'if ! /sbin/mount | /usr/bin/grep -qF "$MOUNT"; then',
      r'  /bin/rm -rf "$WORK"',
      r'fi',
      r'exit "$STATUS"',
    ].join('\n');
  }

  /// Rejects bundle locations the swap script could not replace, while the
  /// app is still alive to surface the reason: running straight off the
  /// mounted DMG, a Gatekeeper-translocated copy, or a directory the user
  /// cannot write into. Called before the download so the failure is instant.
  static void ensureSwappableBundle(String bundlePath) {
    if (bundlePath.startsWith('/Volumes/')) {
      throw StateError(
        'SnipSnap is running from its disk image. '
        'Move it to Applications first, then update.',
      );
    }
    if (bundlePath.contains('/AppTranslocation/')) {
      throw StateError(
        'macOS is running SnipSnap from a temporary location. '
        'Move it to Applications first, then update.',
      );
    }
    final parent = File(bundlePath).parent;
    final probe = File('${parent.path}/.snipsnap-update-probe');
    try {
      probe.writeAsStringSync('');
      probe.deleteSync();
    } on FileSystemException {
      throw StateError(
        'SnipSnap cannot replace itself in ${parent.path}. '
        'Download the update from the release page instead.',
      );
    }
  }

  /// macOS only: downloads the DMG, spawns the detached swap script, and
  /// exits the app so the bundle can be replaced. The script relaunches from
  /// the same bundle path, which survives the in-place swap. Release-only:
  /// a debug run would swap out its own build directory bundle.
  Future<void> downloadAndInstallMacos(
    UpdateInfo info, {
    void Function(int received, int total)? onProgress,
    void Function()? exitApp,
  }) async {
    final asset = info.asset;
    if (asset == null) {
      throw StateError('No macOS disk image asset on this release');
    }
    if (!kReleaseMode) {
      throw StateError(
        'In-app install is release-only — it would swap out this dev build',
      );
    }
    // Both checks run before the download: a bundle the script could never
    // replace fails here, fast, instead of after pulling the whole DMG.
    final bundlePath = macosAppBundlePath(Platform.resolvedExecutable);
    ensureSwappableBundle(bundlePath);
    final workDir = await Directory.systemTemp.createTemp('snipsnap_update_');
    try {
      final dmg = await downloadAsset(
        asset,
        dir: workDir,
        onProgress: onProgress,
      );
      final script = File(
        '${workDir.path}${Platform.pathSeparator}install_update.sh',
      );
      await script.writeAsString(buildMacosInstallScript());
      await Process.start('/bin/sh', [
        script.path,
        dmg.path,
        bundlePath,
        workDir.path,
        '\$pid',
      ], mode: ProcessStartMode.detached);
    } catch (e) {
      // A failed attempt must not strand a full-size DMG per retry.
      try {
        workDir.deleteSync(recursive: true);
      } catch (_) {}
      rethrow;
    }
    (exitApp ?? () => exit(0))();
  }

  /// Command used to open [url] in the default browser on [platform].
  static List<String> openUrlCommand(UpdatePlatform platform, String url) {
    switch (platform) {
      case UpdatePlatform.macos:
        return ['open', url];
      case UpdatePlatform.linux:
        return ['xdg-open', url];
      case UpdatePlatform.windows:
        return ['cmd.exe', '/c', 'start', '', url];
    }
  }

  /// Opens the release page in the default browser.
  Future<void> openReleasePage(UpdateInfo info) async {
    final cmd = openUrlCommand(platform, info.releasePageUrl);
    await Process.start(
      cmd.first,
      cmd.sublist(1),
      mode: ProcessStartMode.detached,
    );
  }
}
