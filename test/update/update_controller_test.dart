import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:snipsnap/services/update/update_controller.dart';
import 'package:snipsnap/services/update/update_info.dart';
import 'package:snipsnap/services/update/update_service.dart';

Map<String, dynamic> release(String tag) => {
  'tag_name': tag,
  'html_url': 'https://example.com/releases/$tag',
  'assets': <dynamic>[],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  UpdateService service({String latestTag = 'v1.1.0', Object? fetchError}) {
    return UpdateService(
      currentVersion: '1.0.0',
      platform: UpdatePlatform.macos,
      fetchRelease: (_) async {
        if (fetchError != null) throw fetchError;
        return release(latestTag);
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
}
