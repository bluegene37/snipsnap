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
    final file = File(
      '${targetDir.path}${Platform.pathSeparator}${asset.name}',
    );

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
