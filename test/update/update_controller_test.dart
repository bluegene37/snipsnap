import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:snipsnap/services/update/update_controller.dart';
import 'package:snipsnap/services/update/update_info.dart';
import 'package:snipsnap/services/update/update_service.dart';

Map<String, dynamic> release(
  String tag, {
  List<String> assetNames = const [],
}) => {
  'tag_name': tag,
  'html_url': 'https://example.com/releases/$tag',
  'assets': [
    for (final name in assetNames)
      {
        'name': name,
        'browser_download_url': 'https://example.com/$name',
        'size': 1,
      },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  UpdateService service({
    String latestTag = 'v1.1.0',
    Object? fetchError,
    UpdatePlatform platform = UpdatePlatform.macos,
    List<String> assetNames = const [],
  }) {
    return UpdateService(
      currentVersion: '1.0.0',
      platform: platform,
      fetchRelease: (_) async {
        if (fetchError != null) throw fetchError;
        return release(latestTag, assetNames: assetNames);
      },
    );
  }

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('silent check exposes an available update and notifies', () async {
    final controller = UpdateController(service: service());
    var notified = 0;
    controller.addListener(() => notified++);

    await controller.checkSilently();

    expect(controller.availableUpdate, isNotNull);
    expect(controller.availableUpdate!.version.toString(), '1.1.0');
    expect(notified, greaterThan(0));
  });

  test('silent check stays quiet when up to date', () async {
    final controller = UpdateController(service: service(latestTag: 'v1.0.0'));
    await controller.checkSilently();
    expect(controller.availableUpdate, isNull);
    expect(controller.lastResult!.status, UpdateStatus.upToDate);
  });

  test('silent check swallows failures without exposing an update', () async {
    final controller = UpdateController(
      service: service(fetchError: Exception('offline')),
    );
    await controller.checkSilently();
    expect(controller.availableUpdate, isNull);
    expect(controller.lastResult!.status, UpdateStatus.failed);
  });

  test('manual check resurfaces a skipped version', () async {
    final controller = UpdateController(service: service());
    await controller.checkSilently();
    await controller.skipAvailableVersion();
    expect(controller.availableUpdate, isNull);

    // Automatic checks respect the skip...
    await controller.checkSilently();
    expect(controller.availableUpdate, isNull);

    // ...but an explicit user-triggered check shows it again.
    await controller.checkManually();
    expect(controller.availableUpdate, isNotNull);
  });

  test('dismiss hides the update for this session only', () async {
    final controller = UpdateController(service: service());
    await controller.checkSilently();
    controller.dismiss();
    expect(controller.availableUpdate, isNull);
    // Not persisted as skipped: the next check surfaces it again.
    await controller.checkManually();
    expect(controller.availableUpdate, isNotNull);
  });

  test('isChecking toggles during a check', () async {
    final controller = UpdateController(service: service());
    final future = controller.checkManually();
    expect(controller.isChecking, isTrue);
    await future;
    expect(controller.isChecking, isFalse);
  });

  test('exposes platform and current version for the dialog copy', () {
    final controller = UpdateController(service: service());
    expect(controller.platform, UpdatePlatform.macos);
    expect(controller.currentVersion, '1.0.0');
  });

  group('canInstallDirectly', () {
    test('true on macOS when the release carries a DMG', () async {
      final controller = UpdateController(
        service: service(assetNames: ['snipsnap-1.1.0.dmg']),
      );
      await controller.checkSilently();
      expect(controller.canInstallDirectly, isTrue);
    });

    test('true on Windows when the release carries an installer', () async {
      final controller = UpdateController(
        service: service(
          platform: UpdatePlatform.windows,
          assetNames: ['snipsnap-1.1.0-installer.exe'],
        ),
      );
      await controller.checkSilently();
      expect(controller.canInstallDirectly, isTrue);
    });

    test('false when the release has no asset for this platform', () async {
      final controller = UpdateController(
        service: service(assetNames: ['snipsnap-1.1.0-installer.exe']),
      );
      await controller.checkSilently();
      expect(controller.availableUpdate, isNotNull);
      expect(controller.canInstallDirectly, isFalse);
    });

    test(
      'false on Linux even with a matching asset — browser fallback',
      () async {
        final controller = UpdateController(
          service: service(
            platform: UpdatePlatform.linux,
            assetNames: ['snipsnap-1.1.0.deb'],
          ),
        );
        await controller.checkSilently();
        expect(controller.canInstallDirectly, isFalse);
      },
    );

    test('false with no update at all', () {
      final controller = UpdateController(service: service());
      expect(controller.canInstallDirectly, isFalse);
    });
  });
}
