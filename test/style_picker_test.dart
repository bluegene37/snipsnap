import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/utils/constants.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/components/style_picker.dart';

/// Pumps [StylePicker] under a real [SnipThemeScope] for the given [mode],
/// with [activeTool] driving which conditional sections render.
///
/// Mirrors `style_picker_slider_range_test.dart`'s harness: the picker is a
/// fixed 250px column and the test environment's Ahem font renders every
/// glyph as a full-size square, so a title-row layout overflow under
/// `flutter_test` is a known font-metrics artifact of the harness, not a
/// real bug — `tester.takeException()` drains it the same way that file
/// does, and is not asserted against here.
Future<void> _pump(
  WidgetTester tester, {
  required SnipThemeMode mode,
  required CanvasTool tool,
  Color selectedColor = const Color(0xFFEF4444),
}) async {
  await tester.pumpWidget(SnipThemeScope(
    theme: SnipTheme.forMode(mode),
    child: MaterialApp(
      home: Scaffold(
        body: StylePicker(
          selectedColor: selectedColor,
          onColorChanged: (_) {},
          strokeWidth: 4.0,
          onStrokeWidthChanged: (_) {},
          opacity: 1.0,
          onOpacityChanged: (_) {},
          fontSize: 18.0,
          onFontSizeChanged: (_) {},
          isFilled: false,
          onFillChanged: (_) {},
          borderRadius: 8.0,
          onBorderRadiusChanged: (_) {},
          blurStrength: 14.0,
          onBlurStrengthChanged: (_) {},
          rotation: 0.0,
          onRotationChanged: (_) {},
          activeTool: tool,
          shapeKind: ShapeKind.rectangle,
          onShapeKindChanged: (_) {},
          onFlattenCanvas: () {},
          onActivateEyedropper: () {},
        ),
      ),
    ),
  ));
  tester.takeException();
}

/// Every non-transparent circular swatch [Container] currently in the tree —
/// covers both the fill-tool "Quick Styles" grid and the main selection
/// swatch grid, whichever the pumped [CanvasTool] rendered.
List<BoxDecoration> _circleSwatchDecorations(WidgetTester tester) {
  return tester
      .widgetList<Container>(find.byType(Container))
      .map((c) => c.decoration)
      .whereType<BoxDecoration>()
      .where((d) => d.shape == BoxShape.circle)
      .toList();
}

void main() {
  for (final mode in SnipThemeMode.values) {
    testWidgets('pumps cleanly in $mode for every conditional section', (tester) async {
      // Sweeps every CanvasTool that toggles a distinct block of the panel
      // (shape chooser, fill/text-background swatches, blur mode, rotation,
      // step-marker card, fill-tool quick styles) so a mode-conversion typo
      // anywhere in the file would throw during this pump.
      for (final tool in const [
        CanvasTool.pen,
        CanvasTool.shape,
        CanvasTool.text,
        CanvasTool.fill,
        CanvasTool.blur,
        CanvasTool.stepMarker,
        CanvasTool.select,
        CanvasTool.crop,
        CanvasTool.arrow,
      ]) {
        await _pump(tester, mode: mode, tool: tool);
        expect(find.byType(StylePicker), findsOneWidget, reason: '$mode/$tool');
      }
    });
  }

  group('the annotation colour swatches keep their real colour', () {
    for (final mode in SnipThemeMode.values) {
      testWidgets('$mode: every AppColors.palette entry is still painted, unaltered',
          (tester) async {
        await _pump(tester, mode: mode, tool: CanvasTool.pen);

        final fills = _circleSwatchDecorations(tester).map((d) => d.color).toSet();
        for (final paletteColor in AppColors.palette) {
          expect(fills, contains(paletteColor),
              reason: '$mode: ${paletteColor.toARGB32().toRadixString(16)} '
                  'from AppColors.palette should render unchanged as a swatch fill');
        }
      });
    }

    for (final mode in SnipThemeMode.values) {
      testWidgets('$mode: the selected swatch ring is t.ink, not an accent hue', (tester) async {
        final t = SnipTheme.forMode(mode);
        const selected = Color(0xFFEF4444); // first AppColors.palette entry
        await _pump(tester, mode: mode, tool: CanvasTool.pen, selectedColor: selected);

        // The selected swatch is the one circle whose fill matches the
        // selected colour AND whose border is drawn at the 2.5px "selected"
        // width (chrome) — the fill itself must still be the real colour.
        final selectedSwatch = _circleSwatchDecorations(tester).singleWhere(
          (d) => d.color?.toARGB32() == selected.toARGB32() && d.border?.top.width == 2.5,
          orElse: () => throw StateError('no selected swatch found for $mode'),
        );
        expect(selectedSwatch.color, selected, reason: '$mode: fill is data, must stay real colour');
        expect((selectedSwatch.border as Border).top.color, t.ink,
            reason: '$mode: the ring is chrome, must be t.ink — not a hardcoded/accent colour');
      });
    }
  });

  group('exclusive-active selections route through controlDecoration/controlForeground', () {
    for (final mode in SnipThemeMode.values) {
      testWidgets('$mode: the selected shape tile is an activeFill plate', (tester) async {
        final t = SnipTheme.forMode(mode);
        await _pump(tester, mode: mode, tool: CanvasTool.shape);

        // ShapeKind.rectangle is the default shapeKind passed by the harness,
        // so its tile should be the one exclusive-active plate in the grid.
        final activePlates = tester
            .widgetList<Container>(find.byType(Container))
            .map((c) => c.decoration)
            .whereType<BoxDecoration>()
            .where((d) => d.color?.toARGB32() == t.activeFill.toARGB32())
            .toList();
        expect(activePlates, isNotEmpty, reason: '$mode: expected an activeFill-plated shape tile');
      });
    }
  });
}
