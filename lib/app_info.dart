/// App identity constants.
///
/// [appVersion] and [appBuild] must mirror `pubspec.yaml`'s `version:` field
/// (`<appVersion>+<appBuild>`) — the update checker compares [appVersion]
/// against GitHub release tags, so a lagging value re-offers the release the
/// user is already running. `test/update/app_info_test.dart` enforces the
/// lockstep.
class AppInfo {
  AppInfo._();

  static const String appName = 'SnipSnap';
  // Gene - Oct, 24, 2026: Bumped appVersion and appBuild to 1.0.5+4 for PDF export release.
  // static const String appVersion = '1.0.4';
  // static const String appBuild = '3';
  // static const String appVersion = '1.0.5';
  // static const String appBuild = '4';
  // Gene - Oct, 31, 2026: Bumped appVersion and appBuild to 1.0.6+5 for release.
  static const String appVersion = '1.0.6';
  static const String appBuild = '5';

  // Gene - Oct, 14, 2026: Added Microsoft Store build flag. Store builds are
  // compiled with `--dart-define=SNIPSNAP_STORE=true` (see msix_config in
  // pubspec.yaml). Microsoft Store policy 10.2.4 / 10.8 forbids apps from
  // downloading or installing updates outside the Store, so the GitHub
  // Releases updater is disabled when this is true.
  static const bool isStoreBuild = bool.fromEnvironment('SNIPSNAP_STORE');
}
