import 'semver.dart';

/// Desktop platform an update asset targets.
enum UpdatePlatform { windows, macos, linux }

/// One downloadable file attached to a GitHub release.
class UpdateAsset {
  const UpdateAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
  });

  final String name;
  final String downloadUrl;
  final int size;
}

/// Parsed view of the GitHub "latest release" payload, narrowed to what the
/// updater needs: the version, the release page, and the asset matching the
/// current platform (if any).
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.releasePageUrl,
    required this.asset,
  });

  final Semver version;
  final String releasePageUrl;
  final UpdateAsset? asset;

  /// Parses [json] (the GitHub REST release object), returning null on an
  /// unparseable tag so a stray non-version release never breaks the check.
  static UpdateInfo? tryFromReleaseJson(
    Map<String, dynamic> json,
    UpdatePlatform platform,
  ) {
    final version = Semver.tryParse(json['tag_name'] as String? ?? '');
    if (version == null) return null;

    final assets = (json['assets'] as List? ?? const [])
        .whereType<Map<dynamic, dynamic>>()
        .map(
          (a) => UpdateAsset(
            name: a['name'] as String? ?? '',
            downloadUrl: a['browser_download_url'] as String? ?? '',
            size: (a['size'] as num?)?.toInt() ?? 0,
          ),
        )
        .toList();

    return UpdateInfo(
      version: version,
      releasePageUrl: json['html_url'] as String? ?? '',
      asset: _selectAsset(assets, platform),
    );
  }

  static UpdateAsset? _selectAsset(
    List<UpdateAsset> assets,
    UpdatePlatform platform,
  ) {
    UpdateAsset? firstWithSuffix(String suffix) {
      for (final asset in assets) {
        if (asset.name.toLowerCase().endsWith(suffix)) return asset;
      }
      return null;
    }

    switch (platform) {
      case UpdatePlatform.windows:
        // Prefer the Inno installer over any other .exe (e.g. portable build).
        return firstWithSuffix('-installer.exe') ?? firstWithSuffix('.exe');
      case UpdatePlatform.macos:
        return firstWithSuffix('.dmg');
      case UpdatePlatform.linux:
        return firstWithSuffix('.deb') ?? firstWithSuffix('.tar.gz');
    }
  }
}
