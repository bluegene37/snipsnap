import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/services/update/update_info.dart';

Map<String, dynamic> releaseJson() => {
  'tag_name': 'v1.2.0',
  'html_url': 'https://github.com/bluegene37/snipsnap/releases/tag/v1.2.0',
  'assets': [
    {
      'name': 'Snipsnap-x86_64-1.2.0+3-Installer.exe',
      'browser_download_url': 'https://example.com/installer.exe',
      'size': 12345,
    },
    {
      'name': 'snipsnap-1.2.0-portable.exe',
      'browser_download_url': 'https://example.com/portable.exe',
      'size': 11111,
    },
    {
      'name': 'snipsnap-1.2.0.dmg',
      'browser_download_url': 'https://example.com/app.dmg',
      'size': 22222,
    },
    {
      'name': 'snipsnap_1.2.0_amd64.deb',
      'browser_download_url': 'https://example.com/app.deb',
      'size': 33333,
    },
    {
      'name': 'snipsnap-1.2.0-linux-x64.tar.gz',
      'browser_download_url': 'https://example.com/app.tar.gz',
      'size': 44444,
    },
  ],
};

void main() {
  group('UpdateInfo.tryFromReleaseJson', () {
    test('parses version from tag_name and keeps release page url', () {
      final info = UpdateInfo.tryFromReleaseJson(
        releaseJson(),
        UpdatePlatform.windows,
      )!;
      expect(info.version.toString(), '1.2.0');
      expect(info.releasePageUrl, contains('/releases/tag/v1.2.0'));
    });

    test('prefers the -Installer.exe over other .exe assets on Windows', () {
      final info = UpdateInfo.tryFromReleaseJson(
        releaseJson(),
        UpdatePlatform.windows,
      )!;
      expect(info.asset, isNotNull);
      expect(info.asset!.name, endsWith('-Installer.exe'));
      expect(info.asset!.downloadUrl, 'https://example.com/installer.exe');
      expect(info.asset!.size, 12345);
    });

    test('falls back to any .exe on Windows when no installer exists', () {
      final json = releaseJson();
      (json['assets'] as List).removeWhere(
        (a) => (a as Map)['name'].toString().endsWith('-Installer.exe'),
      );
      final info = UpdateInfo.tryFromReleaseJson(json, UpdatePlatform.windows)!;
      expect(info.asset!.name, endsWith('portable.exe'));
    });

    test('picks the DMG on macOS', () {
      final info = UpdateInfo.tryFromReleaseJson(
        releaseJson(),
        UpdatePlatform.macos,
      )!;
      expect(info.asset!.name, endsWith('.dmg'));
    });

    test('prefers the .deb over the tarball on Linux', () {
      final info = UpdateInfo.tryFromReleaseJson(
        releaseJson(),
        UpdatePlatform.linux,
      )!;
      expect(info.asset!.name, endsWith('.deb'));
    });

    test('falls back to tarball on Linux when no .deb exists', () {
      final json = releaseJson();
      (json['assets'] as List).removeWhere(
        (a) => (a as Map)['name'].toString().endsWith('.deb'),
      );
      final info = UpdateInfo.tryFromReleaseJson(json, UpdatePlatform.linux)!;
      expect(info.asset!.name, endsWith('.tar.gz'));
    });

    test('suffix match is case-insensitive', () {
      final json = releaseJson();
      json['assets'] = [
        {
          'name': 'SnipSnap-1.2.0.DMG',
          'browser_download_url': 'https://example.com/app.dmg',
          'size': 1,
        },
      ];
      final info = UpdateInfo.tryFromReleaseJson(json, UpdatePlatform.macos)!;
      expect(info.asset, isNotNull);
    });

    test('asset is null when the platform has no matching asset', () {
      final json = releaseJson();
      json['assets'] = <dynamic>[];
      final info = UpdateInfo.tryFromReleaseJson(json, UpdatePlatform.windows)!;
      expect(info.asset, isNull);
      expect(info.releasePageUrl, isNotEmpty);
    });

    test('returns null for a release with an unparseable tag', () {
      final json = releaseJson();
      json['tag_name'] = 'nightly';
      expect(
        UpdateInfo.tryFromReleaseJson(json, UpdatePlatform.windows),
        isNull,
      );
    });

    test('returns null when tag_name is missing entirely', () {
      final json = releaseJson();
      json.remove('tag_name');
      expect(
        UpdateInfo.tryFromReleaseJson(json, UpdatePlatform.windows),
        isNull,
      );
    });
  });
}
