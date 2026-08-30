import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:snipsnap/services/update/update_controller.dart';
import 'package:snipsnap/services/update/update_info.dart';
import 'package:snipsnap/services/update/update_service.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/components/update_check_button.dart';

UpdateController controllerWith({String latestTag = 'v1.0.0', Object? error}) {
  return UpdateController(
    service: UpdateService(
      currentVersion: '1.0.0',
      platform: UpdatePlatform.macos,
      fetchRelease: (_) async {
        if (error != null) throw error;
        return {
          'tag_name': latestTag,
          'html_url': 'https://example.com/releases/$latestTag',
          'assets': <dynamic>[],
        };
      },
    ),
  );
}

Widget host(UpdateController controller) {
  return SnipThemeScope(
    theme: SnipTheme.forMode(SnipThemeMode.light),
    child: MaterialApp(
      home: Scaffold(
        body: Center(child: UpdateCheckButton(controller: controller)),
      ),
    ),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('reports up to date via snackbar', (tester) async {
    await tester.pumpWidget(host(controllerWith()));
    await tester.tap(find.byType(UpdateCheckButton));
    await tester.pumpAndSettle();

    expect(find.textContaining('up to date'), findsOneWidget);
    expect(find.textContaining('snipsnap 1.0.0'), findsOneWidget);
  });

  testWidgets('reports failure via snackbar', (tester) async {
    await tester.pumpWidget(host(controllerWith(error: Exception('offline'))));
    await tester.tap(find.byType(UpdateCheckButton));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not check for updates'), findsOneWidget);
  });

  testWidgets('stays quiet when an update is found (dialog handles it)', (
    tester,
  ) async {
    await tester.pumpWidget(host(controllerWith(latestTag: 'v2.0.0')));
    await tester.tap(find.byType(UpdateCheckButton));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('shows a spinner while the check is in flight', (tester) async {
    final gate = Completer<void>();
    final controller = UpdateController(
      service: UpdateService(
        currentVersion: '1.0.0',
        platform: UpdatePlatform.macos,
        fetchRelease: (_) async {
          await gate.future;
          return {
            'tag_name': 'v1.0.0',
            'html_url': 'https://example.com/releases/v1.0.0',
            'assets': <dynamic>[],
          };
        },
      ),
    );
    await tester.pumpWidget(host(controller));
    await tester.tap(find.byType(UpdateCheckButton));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpAndSettle();
  });
}
