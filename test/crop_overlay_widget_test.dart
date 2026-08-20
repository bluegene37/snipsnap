import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/components/crop_overlay_widget.dart';

/// Pumps [CropOverlayWidget] under a real [SnipThemeScope] for the given
/// [mode]. Unlike EditorCanvas, this widget embeds no `Image.file`, so it can
/// be pumped directly — see the task-5 brief and report for why EditorCanvas
/// itself cannot be.
Future<void> _pump(WidgetTester tester, {required SnipThemeMode mode}) async {
  await tester.pumpWidget(SnipThemeScope(
    theme: SnipTheme.forMode(mode),
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 400,
          child: CropOverlayWidget(
            cropRect: const Rect.fromLTWH(80, 80, 200, 150),
            onCropRectChanged: (_) {},
            onApplyCrop: () {},
            onCancelCrop: () {},
          ),
        ),
      ),
    ),
  ));
}

/// The eight 14x14 corner/midpoint handle marks — corner and midpoint visuals
/// share the exact same decoration shape (`BorderRadius.circular(2)`, unique
/// to these handles among the widget's other decorated containers), so they
/// are not distinguished from one another here.
List<BoxDecoration> _handleDecorations(WidgetTester tester) {
  return tester
      .widgetList<Container>(find.byType(Container))
      .map((c) => c.decoration)
      .whereType<BoxDecoration>()
      .where((d) => d.borderRadius == BorderRadius.circular(2))
      .toList();
}

void main() {
  for (final mode in SnipThemeMode.values) {
    testWidgets('pumps cleanly in $mode', (tester) async {
      await _pump(tester, mode: mode);
      expect(find.byType(CropOverlayWidget), findsOneWidget, reason: '$mode');
      expect(tester.takeException(), isNull, reason: '$mode');
    });
  }

  group('handles are ink marks ringed in the opposite mark tone', () {
    for (final mode in SnipThemeMode.values) {
      testWidgets('$mode: every handle fills with ink and rings with onActive',
          (tester) async {
        final t = SnipTheme.forMode(mode);
        await _pump(tester, mode: mode);

        final decorations = _handleDecorations(tester);
        // 4 corner handles + 4 midpoint handles.
        expect(decorations.length, 8, reason: '$mode');
        for (final d in decorations) {
          expect(d.color, t.ink, reason: '$mode: handle fill must be t.ink');
          expect(d.border?.top.color, t.onActive,
              reason: '$mode: handle ring must contrast its own fill via t.onActive');
        }
      });
    }
  });

  group('the floating action bar uses plain panel chrome, not AppColors.accent', () {
    for (final mode in SnipThemeMode.values) {
      testWidgets('$mode: bar surface, border, and button treatment are theme-driven',
          (tester) async {
        final t = SnipTheme.forMode(mode);
        await _pump(tester, mode: mode);

        // Scaffold, ElevatedButton, OutlinedButton and Tooltip all produce
        // their own Material widgets — the action bar's own is the one with
        // elevation 8, matching the `elevation: 8` set on it in the source.
        final material = tester
            .widgetList<Material>(find.byType(Material))
            .firstWhere((m) => m.elevation == 8);
        expect(material.color, t.surface, reason: '$mode: action bar surface');

        final barContainer = tester
            .widgetList<Container>(find.byType(Container))
            .firstWhere((c) => c.decoration is BoxDecoration &&
                (c.decoration as BoxDecoration).borderRadius ==
                    BorderRadius.circular(20));
        final barDecoration = barContainer.decoration as BoxDecoration;
        expect(barDecoration.border?.top.color, t.border, reason: '$mode: action bar border');

        final applyButton = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
        final applyStyle = applyButton.style!;
        expect(applyStyle.foregroundColor?.resolve({}), t.emphasis,
            reason: '$mode: Apply Crop CTA foreground is border/text-only emphasis');
        expect(applyStyle.backgroundColor?.resolve({}), t.surfaceRaised,
            reason: '$mode: Apply Crop CTA is not a filled accent plate');

        final cancelButton = tester.widget<OutlinedButton>(find.byType(OutlinedButton));
        final cancelStyle = cancelButton.style!;
        expect(cancelStyle.foregroundColor?.resolve({}), t.ink,
            reason: '$mode: Cancel is a plain secondary action');
        expect(cancelStyle.side?.resolve({})?.color, t.border, reason: '$mode: Cancel border');
      });
    }
  });
}
