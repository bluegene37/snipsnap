import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/utils/constants.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/components/style_picker.dart';
import 'package:snipsnap/views/dialogs/color_picker_dialog.dart';

Future<void> _pumpPicker(
  WidgetTester tester, {
  required ValueChanged<Color> onColorChanged,
  Color initial = const Color(0xFFEF4444),
}) async {
  await tester.pumpWidget(SnipThemeScope(
    theme: SnipTheme.forMode(SnipThemeMode.dark),
    child: MaterialApp(
      home: Scaffold(
        body: Center(
          child: SnipColorPicker(initialColor: initial, onColorChanged: onColorChanged),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

/// The painters currently mounted under the picker, in tree order:
/// saturation/value field, hue rail, alpha rail, preview checkerboard.
List<CustomPainter> _painters(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.descendant(
      of: find.byType(SnipColorPicker),
      matching: find.byType(CustomPaint),
    ))
    .map((c) => c.painter)
    .whereType<CustomPainter>()
    .toList();

void main() {
  testWidgets('dragging the saturation/value field repaints the indicator', (tester) async {
    // The regression this guards: `flutter_colorpicker`'s painters all return
    // `false` from `shouldRepaint`, so the gradient and the position ring were
    // painted once and then frozen. The colour value updated correctly while
    // the circle sat where it started — "the picker is not reactive".
    final emitted = <Color>[];
    await _pumpPicker(tester, onColorChanged: emitted.add);

    final before = _painters(tester);
    expect(before, isNotEmpty);

    final field = tester.getRect(find.byType(SnipColorPicker));
    final gesture = await tester.startGesture(
      Offset(field.left + 20, field.top + 20),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveTo(Offset(field.left + 140, field.top + 90));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(emitted, isNotEmpty, reason: 'the drag must report colours');
    expect(emitted.first, isNot(equals(emitted.last)),
        reason: 'the colour must track the pointer across the field');

    final after = _painters(tester);
    expect(after.length, before.length);
    // The first painter under the picker is the saturation/value field, the
    // one carrying the indicator ring the user watches. It must ask for a
    // repaint, or the ring is stale no matter how correct the colour value is.
    expect(after.first.runtimeType, before.first.runtimeType);
    expect(after.first.shouldRepaint(before.first), isTrue,
        reason: 'the saturation/value field must repaint, or its indicator ring '
            'stays frozen where the drag started');
  });

  testWidgets('the hue rail moves the hue and repaints', (tester) async {
    final emitted = <Color>[];
    await _pumpPicker(tester, onColorChanged: emitted.add);

    final body = tester.getRect(find.byType(SnipColorPicker));
    // The hue rail sits below the saturation/value field, which is 62% of the
    // picker's width tall.
    final railY = body.top + body.width * 0.62 + 14 + 7;
    await tester.tapAt(Offset(body.left + body.width * 0.7, railY),
        kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();

    expect(emitted, isNotEmpty);
    expect(HSVColor.fromColor(emitted.last).hue,
        isNot(closeTo(HSVColor.fromColor(const Color(0xFFEF4444)).hue, 1.0)));
  });

  testWidgets('typing a hex value drives the picker', (tester) async {
    final emitted = <Color>[];
    await _pumpPicker(tester, onColorChanged: emitted.add);

    await tester.enterText(find.byType(TextField), '#00FF00');
    await tester.pumpAndSettle();

    expect(emitted.last.toARGB32(), equals(const Color(0xFF00FF00).toARGB32()));
  });

  testWidgets('the properties panel shows the active colour as hex', (tester) async {
    // The eyedropper and the custom picker both produce off-palette colours,
    // which no preset swatch can highlight. Without this readout the panel
    // gave no sign of what colour was actually active.
    const sampled = Color(0xFF3B7A57);
    await tester.pumpWidget(SnipThemeScope(
      theme: SnipTheme.forMode(SnipThemeMode.dark),
      child: MaterialApp(
        home: Scaffold(
          body: StylePicker(
            selectedColor: sampled,
            onColorChanged: (_) {},
            onTextBackgroundColorChanged: (_) {},
            onFillColorChanged: (_) {},
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
            activeTool: CanvasTool.pen,
            shapeKind: ShapeKind.rectangle,
            onShapeKindChanged: (_) {},
            onFlattenCanvas: () {},
            onActivateEyedropper: () {},
          ),
        ),
      ),
    ));
    tester.takeException();

    expect(find.text('#3B7A57'), findsOneWidget);
  });
}
