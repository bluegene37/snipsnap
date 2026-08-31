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
  static const String appVersion = '1.0.2';
  static const String appBuild = '2';
}
