import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/utils/constants.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/components/style_picker.dart';

/// Pumps the picker with the given scalars and returns every [Slider] it built.
///
/// `Slider`'s own constructor asserts `value >= min && value <= max`, so an
/// out-of-range scalar does not merely look wrong — it throws during build and
/// takes the whole properties panel down (a red screen in debug). That makes
/// "the slider exists and holds an in-range value" a sufficient probe: if the
/// clamp were missing, the widget would never be constructed at all.
///
/// Layout exceptions are deliberately not asserted on here. The picker is a
/// fixed 250px column and the test environment's Ahem font renders every glyph
/// as a full-size square, so the title row overflows under `flutter_test` and
/// only under `flutter_test`. That is a font-metrics artifact of the harness,
/// unrelated to slider ranges.
Future<List<Slider>> _slidersFor(
  WidgetTester tester, {
  required CanvasTool tool,
  required double fontSize,
  required double opacity,
  required double strokeWidth,
  required double borderRadius,
  required double blurStrength,
}) async {
  // StylePicker sizes itself (250 x double.infinity) and scrolls internally,
  // so it goes straight into the body. It now reads SnipTheme.of(context)
  // in build(), so it needs a SnipThemeScope ancestor to pump at all — this
  // is infrastructure, not a behavioural change; the mode itself is
  // irrelevant to what these tests assert (slider clamping).
  await tester.pumpWidget(
    SnipThemeScope(
      theme: SnipTheme.forMode(SnipThemeMode.dark),
      child: MaterialApp(
        home: Scaffold(
          body: StylePicker(
            selectedColor: Colors.red,
            onColorChanged: (_) {},
            strokeWidth: strokeWidth,
            onStrokeWidthChanged: (_) {},
            opacity: opacity,
            onOpacityChanged: (_) {},
            fontSize: fontSize,
            onFontSizeChanged: (_) {},
            isFilled: false,
            onFillChanged: (_) {},
            borderRadius: borderRadius,
            onBorderRadiusChanged: (_) {},
            blurStrength: blurStrength,
            onBlurStrengthChanged: (_) {},
            activeTool: tool,
          ),
        ),
      ),
    ),
  );
  // Drains the harness-only layout overflow described above, which would
  // otherwise fail the test on its own. A missing clamp still fails loudly:
  // the assert fires inside `Slider`'s constructor while the children list is
  // being built, so the panel never renders and no Slider is found at all.
  tester.takeException();
  return tester.widgetList<Slider>(find.byType(Slider)).toList();
}

void main() {
  // Every slider in the picker is fed a persisted or derived scalar, and
  // several of those are now canvas-space values computed as `stored / scale`.
  // Shrink the window enough and any of them can land outside the slider's
  // declared range.

  testWidgets('a font size below the slider minimum is clamped, not asserted', (
    tester,
  ) async {
    // 60pt stored on a 4K screenshot shown in a small window projects to well
    // under the 10pt floor.
    final sliders = await _slidersFor(
      tester,
      tool: CanvasTool.text,
      fontSize: 3.4,
      opacity: 1.0,
      strokeWidth: 2.0,
      borderRadius: 8.0,
      blurStrength: 14.0,
    );

    final fontSlider = sliders.singleWhere(
      (s) => s.min == 10.0 && s.max == 60.0,
    );
    expect(fontSlider.value, 10.0);
  });

  testWidgets('an opacity below the slider minimum is clamped, not asserted', (
    tester,
  ) async {
    final sliders = await _slidersFor(
      tester,
      tool: CanvasTool.text,
      fontSize: 20.0,
      opacity: 0.0,
      strokeWidth: 2.0,
      borderRadius: 8.0,
      blurStrength: 14.0,
    );

    final opacitySlider = sliders.singleWhere(
      (s) => s.min == 0.1 && s.max == 1.0,
    );
    expect(opacitySlider.value, 0.1);
  });

  testWidgets('no slider is ever fed a value outside its own range', (
    tester,
  ) async {
    // The general invariant, so a slider added later is covered too. Every
    // scalar is pushed past both ends of its range at once.
    for (final tool in const [
      CanvasTool.text,
      CanvasTool.shape,
      CanvasTool.blur,
      CanvasTool.pen,
    ]) {
      for (final extreme in const [-1000.0, 1000.0]) {
        final sliders = await _slidersFor(
          tester,
          tool: tool,
          fontSize: extreme,
          opacity: extreme,
          strokeWidth: extreme,
          borderRadius: extreme,
          blurStrength: extreme,
        );
        expect(sliders, isNotEmpty, reason: 'tool=$tool extreme=$extreme');
        for (final s in sliders) {
          expect(
            s.value,
            greaterThanOrEqualTo(s.min),
            reason: 'tool=$tool extreme=$extreme',
          );
          expect(
            s.value,
            lessThanOrEqualTo(s.max),
            reason: 'tool=$tool extreme=$extreme',
          );
        }
      }
    }
  });
}
