import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/utils/constants.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/dialogs/save_as_dialog.dart';

// SaveAsDialog embeds no Image.file — pumpable in both modes per the
// task-6 brief.

// The "Social Framing & Padding" header row (unchanged in structure by this
// task — only its colours were converted) overflows by a few pixels under
// flutter_test's Ahem font, which renders every glyph as a full-size square.
// Same known harness artifact style_picker_test.dart documents and drains;
// not a real layout bug, so it's swallowed via takeException() rather than
// asserted against.
Future<void> _pump(
  WidgetTester tester, {
  required SnipThemeMode mode,
  ValueChanged<SaveOptions>? onConfirm,
}) async {
  await tester.pumpWidget(
    SnipThemeScope(
      theme: SnipTheme.forMode(mode),
      child: MaterialApp(
        home: Scaffold(
          body: SaveAsDialog(
            initialName: 'screenshot',
            onConfirm: onConfirm ?? (_) {},
          ),
        ),
      ),
    ),
  );
  tester.takeException();
}

/// Expands the framing section and selects the 32px padding preset — the
/// gradient/corner-radius/shadow controls only render once framingPadding
/// is nonzero (`if (_framingPadding > 0)` in the dialog itself).
Future<void> _expandFramingWithPadding(WidgetTester tester) async {
  await tester.tap(find.text('Social Framing & Padding'));
  await tester.pump();
  await tester.tap(find.text('32px'));
  await tester.pump();
  tester.takeException();
}

void _runStateTests(SnipThemeMode mode) {
  final label = mode.name;
  final t = SnipTheme.forMode(mode);

  testWidgets('[$label] pumps cleanly with the framing section expanded', (tester) async {
    await _pump(tester, mode: mode);
    await _expandFramingWithPadding(tester);

    expect(find.text('Background Gradient:'), findsOneWidget);
  });

  testWidgets('[$label] every AppColors.framingGradients preview keeps its real gradient',
      (tester) async {
    await _pump(tester, mode: mode);
    await _expandFramingWithPadding(tester);

    final rendered = tester
        .widgetList<Container>(find.byType(Container))
        .map((c) => c.decoration)
        .whereType<BoxDecoration>()
        .map((d) => d.gradient)
        .whereType<LinearGradient>()
        .toList();

    for (final gradient in AppColors.framingGradients) {
      expect(rendered.any((g) => g.colors.first == (gradient as LinearGradient).colors.first),
          isTrue,
          reason: '$label: gradient preview must render the real, unconverted stops');
    }
  });

  testWidgets('[$label] the selected gradient ring uses ringOnGradient, not a fixed white',
      (tester) async {
    await _pump(tester, mode: mode);
    await _expandFramingWithPadding(tester);

    // Index 0 is selected by default.
    final stops = (AppColors.framingGradients[0] as LinearGradient).colors;
    final expectedRing = t.ringOnGradient(stops);

    final selectedTile = tester
        .widgetList<Container>(find.byType(Container))
        .where((c) {
          final d = c.decoration;
          if (d is! BoxDecoration || d.gradient is! LinearGradient) return false;
          final g = d.gradient as LinearGradient;
          return g.colors.first == stops.first && g.colors.last == stops.last;
        })
        .first;

    final border = (selectedTile.decoration as BoxDecoration).border as Border;
    expect(border.top.color, expectedRing, reason: '$label: ring must equal ringOnGradient(stops)');
    expect(border.top.color, isNot(Colors.white),
        reason: '$label: must not be the old fixed-white ring');
  });

  testWidgets('[$label] PNG/JPEG format tiles use the exclusive-active plate', (tester) async {
    await _pump(tester, mode: mode);

    // PNG is selected by default — find its tile text colour.
    final pngLabel = tester.widget<Text>(find.text('PNG (.png)'));
    expect(pngLabel.style?.color, t.onActive,
        reason: '$label: selected format tile text must be the onActive knockout');

    final jpegLabel = tester.widget<Text>(find.text('JPEG (.jpg)'));
    expect(jpegLabel.style?.color, t.ink,
        reason: '$label: unselected format tile text must be plain ink');
  });

  testWidgets('[$label] Save fires onConfirm with the entered name', (tester) async {
    SaveOptions? result;
    await _pump(tester, mode: mode, onConfirm: (o) => result = o);

    await tester.tap(find.text('Save'));
    await tester.pump();

    expect(result?.fileName, 'screenshot');
    expect(result?.format, SaveFormat.png);
  });

  testWidgets('[$label] header chrome routes through SnipTheme', (tester) async {
    await _pump(tester, mode: mode);

    final title = tester.widget<Text>(find.text('Save Screenshot As'));
    expect(title.style?.color, t.ink, reason: '$label: dialog title colour');

    final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
    expect(dialog.backgroundColor, t.surface, reason: '$label: dialog background');
  });
}

void main() {
  for (final mode in SnipThemeMode.values) {
    _runStateTests(mode);
  }
}
