import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/app_info.dart';

void main() {
  test('AppInfo mirrors pubspec.yaml version in lockstep', () {
    // The release contract requires the in-app version constant to be bumped
    // together with pubspec.yaml — if it lags, the updater re-offers the
    // version the user is already running. This test makes the bump
    // impossible to forget.
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(
      r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(
      match,
      isNotNull,
      reason: 'pubspec.yaml must declare version: X.Y.Z+N',
    );

    expect(AppInfo.appVersion, match!.group(1));
    expect(AppInfo.appBuild, match.group(2));
  });

  test('AppInfo carries the display name', () {
    expect(AppInfo.appName, 'snipsnap');
  });
}
