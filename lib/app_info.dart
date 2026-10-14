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
  static const String appVersion = '1.0.4';
  static const String appBuild = '3';

  // Gene - Oct, 14, 2026: Added Microsoft Store build flag. Store builds are
  // compiled with `--dart-define=SNIPSNAP_STORE=true` (see msix_config in
  // pubspec.yaml). Microsoft Store policy 10.2.4 / 10.8 forbids apps from
  // downloading or installing updates outside the Store, so the GitHub
  // Releases updater is disabled when this is true.
  static const bool isStoreBuild = bool.fromEnvironment('SNIPSNAP_STORE');
}
