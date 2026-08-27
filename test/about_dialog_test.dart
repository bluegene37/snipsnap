import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/dialogs/about_dialog.dart';

// AboutSnipSnapDialog embeds an Image.asset (not Image.file) for the app
// logo — asset loading is safe under flutter_test (unlike Image.file, which
// hangs the tester per the task-5/6 briefs), and its errorBuilder covers the
// case where the asset bundle isn't wired up in the test environment.

Future<void> _pump(WidgetTester tester, {required SnipThemeMode mode}) {
  return tester.pumpWidget(
    SnipThemeScope(
      theme: SnipTheme.forMode(mode),
      child: const MaterialApp(home: Scaffold(body: AboutSnipSnapDialog())),
    ),
  );
}

void _runStateTests(SnipThemeMode mode) {
  final label = mode.name;
  final t = SnipTheme.forMode(mode);

  testWidgets('[$label] pumps cleanly and shows the app name and version', (
    tester,
  ) async {
    await _pump(tester, mode: mode);
    // The asset almost certainly fails to resolve under flutter_test's
    // bundle — drain that expected error rather than assert on it.
    tester.takeException();

    expect(find.text('snipsnap'), findsOneWidget);
    expect(find.text('Version 1.0.0 (Build 1)'), findsOneWidget);
  });

  testWidgets('[$label] chrome routes through SnipTheme', (tester) async {
    await _pump(tester, mode: mode);
    tester.takeException();

    final dialog = tester.widget<Dialog>(find.byType(Dialog));
    expect(
      dialog.backgroundColor,
      t.surface,
      reason: '$label: dialog background',
    );

    final title = tester.widget<Text>(find.text('snipsnap'));
    expect(title.style?.color, t.ink, reason: '$label: app name colour');

    final version = tester.widget<Text>(find.text('Version 1.0.0 (Build 1)'));
    expect(version.style?.color, t.inkMuted, reason: '$label: version colour');
  });

  testWidgets(
    '[$label] the Close CTA uses the emphasis token as a border/text, never a fill',
    (tester) async {
      await _pump(tester, mode: mode);
      tester.takeException();

      final button = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Close'),
      );
      final style = button.style!;
      expect(
        style.foregroundColor?.resolve({}),
        t.emphasis,
        reason: '$label: Close foreground',
      );
      expect(
        style.backgroundColor?.resolve({}),
        t.surfaceRaised,
        reason:
            '$label: Close background must stay surfaceRaised, not a filled plate',
      );
      expect(
        style.side?.resolve({})?.color,
        t.emphasis,
        reason: '$label: Close border',
      );
    },
  );

  testWidgets('[$label] Close pops the dialog', (tester) async {
    await tester.pumpWidget(
      SnipThemeScope(
        theme: SnipTheme.forMode(mode),
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const AboutSnipSnapDialog(),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    tester.takeException();
    expect(find.text('snipsnap'), findsOneWidget);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    tester.takeException();

    expect(find.text('snipsnap'), findsNothing);
  });
}

void main() {
  for (final mode in SnipThemeMode.values) {
    _runStateTests(mode);
  }
}
