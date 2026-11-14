// Gene - Nov, 14, 2026: Added widget tests for UpdateDialog states and user actions.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:snipsnap/services/update/update_controller.dart';
import 'package:snipsnap/services/update/update_info.dart';
import 'package:snipsnap/services/update/update_service.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/dialogs/update_dialog.dart';

Map<String, dynamic> _releaseJson(
  String tag, {
  List<String> assetNames = const <String>[],
}) => <String, dynamic>{
  'tag_name': tag,
  'html_url': 'https://example.com/releases/$tag',
  'assets': <Map<String, Object>>[
    for (final name in assetNames)
      <String, Object>{
        'name': name,
        'browser_download_url': 'https://example.com/$name',
        'size': 1024,
      },
  ],
};

class _FakeUpdateService extends UpdateService {
  _FakeUpdateService({
    super.platform = UpdatePlatform.macos,
    required super.fetchRelease,
    this.onInstallMacos,
  }) : super(currentVersion: '1.0.0');

  final Future<void> Function(
    UpdateInfo info,
    void Function(int received, int total)? onProgress,
  )?
  onInstallMacos;

  final List<String> openedUrls = <String>[];

  @override
  Future<void> downloadAndInstallMacos(
    UpdateInfo info, {
    void Function(int received, int total)? onProgress,
    void Function()? exitApp,
  }) async {
    if (onInstallMacos != null) {
      await onInstallMacos!(info, onProgress);
    }
  }

  @override
  Future<void> openReleasePage(UpdateInfo info) async {
    openedUrls.add(info.releasePageUrl);
  }
}

Widget _wrap({
  required Widget child,
  SnipThemeMode mode = SnipThemeMode.light,
}) {
  return SnipThemeScope(
    theme: SnipTheme.forMode(mode),
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets(
    'renders empty SizedBox when availableUpdate is null and collapses on dismiss',
    (tester) async {
      final service = _FakeUpdateService(
        fetchRelease: (_) async => _releaseJson('v1.1.0'),
      );
      final controller = UpdateController(service: service);

      await tester.pumpWidget(_wrap(child: UpdateDialog(controller: controller)));
      expect(find.byType(Dialog), findsNothing);
      expect(find.text('Update Available'), findsNothing);

      await controller.checkSilently();
      await tester.pump();
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('Update Available'), findsOneWidget);

      controller.dismiss();
      await tester.pump();
      expect(find.byType(Dialog), findsNothing);
    },
  );

  testWidgets(
    'shows direct install copy and Install & Restart CTA when platform asset exists',
    (tester) async {
      final service = _FakeUpdateService(
        platform: UpdatePlatform.macos,
        fetchRelease: (_) async => _releaseJson(
          'v1.1.0',
          assetNames: const <String>['snipsnap-1.1.0.dmg'],
        ),
      );
      final controller = UpdateController(service: service);
      await controller.checkSilently();

      await tester.pumpWidget(_wrap(child: UpdateDialog(controller: controller)));

      expect(
        find.text('SnipSnap 1.1.0 is available. You are on 1.0.0.'),
        findsOneWidget,
      );
      expect(
        find.text(
          'The update installs in the background and the app restarts automatically.',
        ),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(ElevatedButton, 'Install & Restart'),
        findsOneWidget,
      );
      expect(find.widgetWithText(ElevatedButton, 'Download'), findsNothing);
    },
  );

  testWidgets(
    'shows browser fallback copy and Download CTA opens release page when no asset exists',
    (tester) async {
      final service = _FakeUpdateService(
        platform: UpdatePlatform.linux,
        fetchRelease: (_) async => _releaseJson(
          'v1.1.0',
          assetNames: const <String>['snipsnap-1.1.0.deb'],
        ),
      );
      final controller = UpdateController(service: service);
      await controller.checkSilently();

      await tester.pumpWidget(_wrap(child: UpdateDialog(controller: controller)));

      expect(
        find.text('The download page opens in your browser.'),
        findsOneWidget,
      );
      final downloadBtn = find.widgetWithText(ElevatedButton, 'Download');
      expect(downloadBtn, findsOneWidget);
      expect(
        find.widgetWithText(ElevatedButton, 'Install & Restart'),
        findsNothing,
      );

      await tester.tap(downloadBtn);
      await tester.pump();

      expect(service.openedUrls, <String>['https://example.com/releases/v1.1.0']);
    },
  );

  testWidgets(
    'displays download progress and disables all action buttons while downloading',
    (tester) async {
      final installGate = Completer<void>();
      void Function(int received, int total)? capturedProgress;
      final service = _FakeUpdateService(
        platform: UpdatePlatform.macos,
        fetchRelease: (_) async => _releaseJson(
          'v1.1.0',
          assetNames: const <String>['snipsnap-1.1.0.dmg'],
        ),
        onInstallMacos: (info, onProgress) {
          capturedProgress = onProgress;
          return installGate.future;
        },
      );
      final controller = UpdateController(service: service);
      await controller.checkSilently();

      await tester.pumpWidget(_wrap(child: UpdateDialog(controller: controller)));

      await tester.tap(
        find.widgetWithText(ElevatedButton, 'Install & Restart'),
      );
      await tester.pump();

      expect(capturedProgress, isNotNull);
      capturedProgress!(42, 100);
      await tester.pump();

      final indicator = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(indicator.value, closeTo(0.42, 0.001));
      expect(find.text('Downloading… 42%'), findsOneWidget);

      final skipBtn = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Skip this version'),
      );
      final laterBtn = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Later'),
      );
      final installBtn = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Install & Restart'),
      );
      expect(skipBtn.onPressed, isNull);
      expect(laterBtn.onPressed, isNull);
      expect(installBtn.onPressed, isNull);

      installGate.complete();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'surfaces installError and Open release page fallback button when install fails',
    (tester) async {
      final service = _FakeUpdateService(
        platform: UpdatePlatform.macos,
        fetchRelease: (_) async => _releaseJson(
          'v1.1.0',
          assetNames: const <String>['snipsnap-1.1.0.dmg'],
        ),
        onInstallMacos: (_, _) async {
          throw StateError('Read-only volume');
        },
      );
      final controller = UpdateController(service: service);
      await controller.checkSilently();

      await tester.pumpWidget(
        _wrap(
          mode: SnipThemeMode.dark,
          child: UpdateDialog(controller: controller),
        ),
      );

      await tester.tap(
        find.widgetWithText(ElevatedButton, 'Install & Restart'),
      );
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Update failed: Bad state: Read-only volume. '
          'Use the release page to download it manually.',
        ),
        findsOneWidget,
      );

      final skipBtn = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Skip this version'),
      );
      final laterBtn = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Later'),
      );
      final installBtn = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Install & Restart'),
      );
      expect(skipBtn.onPressed, isNotNull);
      expect(laterBtn.onPressed, isNotNull);
      expect(installBtn.onPressed, isNotNull);

      final openReleaseBtn = find.widgetWithText(
        TextButton,
        'Open release page',
      );
      expect(openReleaseBtn, findsOneWidget);
      await tester.tap(openReleaseBtn);
      await tester.pump();

      expect(service.openedUrls, <String>['https://example.com/releases/v1.1.0']);
    },
  );

  testWidgets(
    'Later and Skip this version pop dialog route and persist skip preference appropriately',
    (tester) async {
      final service = _FakeUpdateService(
        platform: UpdatePlatform.macos,
        fetchRelease: (_) async => _releaseJson(
          'v1.1.0',
          assetNames: const <String>['snipsnap-1.1.0.dmg'],
        ),
      );
      final controller = UpdateController(service: service);
      await controller.checkSilently();

      await tester.pumpWidget(
        _wrap(
          child: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () {
                unawaited(
                  showDialog<void>(
                    context: context,
                    builder: (_) => UpdateDialog(controller: controller),
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.byType(UpdateDialog), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Later'));
      await tester.pumpAndSettle();
      expect(find.byType(UpdateDialog), findsNothing);
      expect(controller.availableUpdate, isNull);

      final prefsAfterLater = await SharedPreferences.getInstance();
      expect(prefsAfterLater.getString('update_skipped_version'), isNull);

      await controller.checkManually();
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.byType(UpdateDialog), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Skip this version'));
      await tester.pumpAndSettle();
      expect(find.byType(UpdateDialog), findsNothing);
      expect(controller.availableUpdate, isNull);

      final prefsAfterSkip = await SharedPreferences.getInstance();
      expect(prefsAfterSkip.getString('update_skipped_version'), '1.1.0');
    },
  );
}
