import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:snipsnap/services/update/update_controller.dart';
import 'package:snipsnap/services/update/update_info.dart';
import 'package:snipsnap/services/update/update_service.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/components/update_gate.dart';

Map<String, dynamic> release(String tag, {bool withInstaller = false}) => {
  'tag_name': tag,
  'html_url': 'https://example.com/releases/$tag',
  'assets': withInstaller
      ? [
          {
            'name': 'Snipsnap-x86_64-$tag-Installer.exe',
            'browser_download_url': 'https://example.com/installer.exe',
            'size': 10,
          },
        ]
      : <dynamic>[],
};

UpdateController controllerWith({
  String latestTag = 'v1.1.0',
  UpdatePlatform platform = UpdatePlatform.macos,
  bool withInstaller = false,
}) {
  return UpdateController(
    service: UpdateService(
      currentVersion: '1.0.0',
      platform: platform,
      fetchRelease: (_) async =>
          release(latestTag, withInstaller: withInstaller),
    ),
  );
}

Widget host(UpdateController controller) {
  return SnipThemeScope(
    theme: SnipTheme.forMode(SnipThemeMode.light),
    child: MaterialApp(
      home: UpdateGate(
        controller: controller,
        child: const Scaffold(body: Text('app body')),
      ),
    ),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('shows the update dialog when a newer release exists', (
    tester,
  ) async {
    await tester.pumpWidget(host(controllerWith()));
    await tester.pumpAndSettle();

    expect(find.text('app body'), findsOneWidget);
    expect(find.text('Update Available'), findsOneWidget);
    expect(find.textContaining('snipsnap 1.1.0 is available'), findsOneWidget);
    expect(find.textContaining('You are on 1.0.0'), findsOneWidget);
  });

  testWidgets('shows nothing when up to date', (tester) async {
    await tester.pumpWidget(host(controllerWith(latestTag: 'v1.0.0')));
    await tester.pumpAndSettle();

    expect(find.text('Update Available'), findsNothing);
  });

  testWidgets('Later closes the dialog for the session', (tester) async {
    final controller = controllerWith();
    await tester.pumpWidget(host(controller));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();

    expect(find.text('Update Available'), findsNothing);
    expect(controller.availableUpdate, isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('update_skipped_version'), isNull);
  });

  testWidgets('Skip persists the skipped version', (tester) async {
    final controller = controllerWith();
    await tester.pumpWidget(host(controller));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Skip this version'));
    await tester.pumpAndSettle();

    expect(find.text('Update Available'), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('update_skipped_version'), '1.1.0');
  });

  testWidgets('reopens for a later manual check after Later', (tester) async {
    final controller = controllerWith();
    await tester.pumpWidget(host(controller));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    expect(find.text('Update Available'), findsNothing);

    // The guard flag must reset when the dialog closes, so a manual check
    // that finds the update again can show it again.
    await controller.checkManually();
    await tester.pumpAndSettle();
    expect(find.text('Update Available'), findsOneWidget);
  });

  testWidgets('non-Windows platforms offer Download, not silent install', (
    tester,
  ) async {
    await tester.pumpWidget(host(controllerWith()));
    await tester.pumpAndSettle();

    expect(find.text('Download'), findsOneWidget);
    expect(find.text('Install & Restart'), findsNothing);
  });

  testWidgets('Windows with an installer asset offers Install & Restart', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        controllerWith(platform: UpdatePlatform.windows, withInstaller: true),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Install & Restart'), findsOneWidget);
    expect(find.text('Download'), findsNothing);
  });
}
