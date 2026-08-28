import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:snipsnap/services/update/update_controller.dart';
import 'package:snipsnap/services/update/update_info.dart';
import 'package:snipsnap/services/update/update_service.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/components/header_bar.dart';
import 'package:snipsnap/views/components/update_check_button.dart';

Widget _harness({UpdateController? updateController}) {
  return SnipThemeScope(
    theme: SnipTheme.forMode(SnipThemeMode.dark),
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 1440,
          child: HeaderBar(
            onSnipInteractive: () {},
            onSnipFullScreen: () {},
            onSnipTimer: () {},
            onImportImage: () {},
            onUndo: () {},
            onRedo: () {},
            onClear: () {},
            onCopyToClipboard: () {},
            onSaveAs: () {},
            onToggleSidebar: () {},
            onToggleProperties: () {},
            onOpenShortcutSettings: () {},
            onToggleThemeMode: () {},
            onOpenAboutDialog: () {},
            canUndo: false,
            canRedo: false,
            hasCapture: false,
            isSidebarOpen: true,
            updateController: updateController,
          ),
        ),
      ),
    ),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('shows the update check button when given a controller', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = UpdateController(
      service: UpdateService(
        currentVersion: '1.0.0',
        platform: UpdatePlatform.macos,
        fetchRelease: (_) async => <String, dynamic>{},
      ),
    );
    await tester.pumpWidget(_harness(updateController: controller));
    expect(find.byType(UpdateCheckButton), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('omits the update check button without a controller', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness());
    expect(find.byType(UpdateCheckButton), findsNothing);
  });
}
