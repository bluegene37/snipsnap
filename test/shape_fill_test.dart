import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:snipsnap/models/annotation.dart';
import 'package:snipsnap/services/render_service.dart';
import 'package:snipsnap/utils/constants.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/components/style_picker.dart';

/// Pumps the panel on the shape tool with fill switched on.
Future<Color?> _pumpFillPanel(
  WidgetTester tester, {
  Color? fillColor,
  required ValueChanged<Color?> onFillColorChanged,
}) async {
  // No scroll view: the panel sizes itself to fill a drawer, so an unbounded
  // parent makes its height infinite. A tall surface instead, so every section
  // is laid out and tappable.
  await tester.binding.setSurfaceSize(const Size(420, 2600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(SnipThemeScope(
    theme: SnipTheme.forMode(SnipThemeMode.dark),
    child: MaterialApp(
      home: Scaffold(
        body: StylePicker(
          selectedColor: const Color(0xFFEF4444),
          onColorChanged: (_) {},
          onTextBackgroundColorChanged: (_) {},
          fillColor: fillColor,
          onFillColorChanged: onFillColorChanged,
          strokeWidth: 4.0,
          onStrokeWidthChanged: (_) {},
          opacity: 1.0,
          onOpacityChanged: (_) {},
          fontSize: 18.0,
          onFontSizeChanged: (_) {},
          isFilled: true,
          onFillChanged: (_) {},
          borderRadius: 8.0,
          onBorderRadiusChanged: (_) {},
          blurStrength: 14.0,
          onBlurStrengthChanged: (_) {},
          activeTool: CanvasTool.shape,
          shapeKind: ShapeKind.rectangle,
          onShapeKindChanged: (_) {},
          savedColors: const [Color(0xFF123456)],
          onFlattenCanvas: () {},
          onActivateEyedropper: () {},
        ),
      ),
    ),
  ));
  while (tester.takeException() != null) {}
  return fillColor;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late String path;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('snipsnap_fill');
    path = '${dir.path}/source.png';
    final image = img.Image(width: 400, height: 400);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    await File(path).writeAsBytes(img.encodePng(image));
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  Future<img.Pixel> renderAndSampleCentre(Annotation ann) async {
    final bytes = await RenderService.renderFlattenedPng(
      imagePath: path,
      annotations: [ann],
      canvasSize: const Size(400, 400),
    );
    final out = img.decodeImage(bytes!)!;
    return out.getPixel(200, 200);
  }

  Annotation filledSquare({Color? fillColor, double opacity = 1.0}) => Annotation(
        id: 'a',
        tool: CanvasTool.shape,
        color: const Color(0xFFFF0000),
        fillColor: fillColor,
        fill: true,
        shapeKind: ShapeKind.rectangle,
        opacity: opacity,
        strokeWidth: 4,
        startPoint: const Offset(100, 100),
        endPoint: const Offset(300, 300),
      );

  test('a filled shape with no fill colour is solid, not a 25% wash', () async {
    // The fill used to fall back to the stroke colour at a hardcoded 25% alpha,
    // which was a third transparency control stacked under the fill-colour and
    // opacity settings the panel already offers — a shape set to solid red at
    // full opacity still came out pink.
    final px = await renderAndSampleCentre(filledSquare());

    expect(px.r, greaterThan(240), reason: 'red channel must be the full colour');
    expect(px.g, lessThan(20), reason: 'a 25% wash over white would leave ~191 here');
    expect(px.b, lessThan(20));
  });

  test('an explicit fill colour still wins', () async {
    final px = await renderAndSampleCentre(
      filledSquare(fillColor: const Color(0xFF0000FF)),
    );

    expect(px.b, greaterThan(240));
    expect(px.r, lessThan(20));
  });

  test('the outline opacity slider leaves the fill alone', () async {
    // The OPACITY slider is the outline's. It used to multiply into the fill
    // too, so fading the border faded the centre with it and the two could
    // not be set independently now that the fill has a slider of its own.
    final px = await renderAndSampleCentre(filledSquare(opacity: 0.5));

    expect(px.r, greaterThan(240));
    expect(px.g, lessThan(20),
        reason: 'a half-opacity outline must not thin the solid fill');
  });

  test('the fill alpha is what makes a fill translucent', () async {
    final px = await renderAndSampleCentre(
      filledSquare(fillColor: const Color(0xFFFF0000).withValues(alpha: 0.5)),
    );

    expect(px.g, greaterThan(100),
        reason: 'half-alpha red over white must let white through');
    expect(px.g, lessThan(200));
  });

  testWidgets('the fill offers the same palette as the outline colour', (tester) async {
    Color? picked;
    await _pumpFillPanel(tester,
        fillColor: const Color(0xFF10B981),
        onFillColorChanged: (c) => picked = c);

    expect(find.text('FILL COLOUR'), findsOneWidget);
    expect(find.text('FILL OPACITY'), findsOneWidget);

    // Every outline palette entry is reachable as a fill, plus the saved
    // swatch and the custom picker — the fill used to offer seven fixed
    // pre-tinted colours and nothing else.
    final circles = tester
        .widgetList<Container>(find.byType(Container))
        .map((c) => c.decoration)
        .whereType<BoxDecoration>()
        .where((d) => d.shape == BoxShape.circle)
        .map((d) => d.color?.toARGB32())
        .toSet();
    for (final c in AppColors.palette) {
      expect(circles, contains(c.toARGB32()),
          reason: '$c must be offered as a fill');
    }
    expect(circles, contains(const Color(0xFF123456).toARGB32()),
        reason: 'saved colours are offered for the fill too');
    expect(picked, isNull);
  });

  testWidgets('the fill opacity slider writes the alpha channel', (tester) async {
    Color? picked;
    // A distinctive starting alpha, so the fill slider is tellable apart from
    // the annotation-wide opacity slider, which also runs 0..1.
    await _pumpFillPanel(tester,
        fillColor: const Color(0xFF10B981).withValues(alpha: 0.6),
        onFillColorChanged: (c) => picked = c);

    // The fill's transparency rides in its own colour's alpha rather than a
    // separate field, so it persists and exports with no model change.
    final sliders = find.byType(Slider).evaluate().map((e) => e.widget as Slider);
    final fillSlider = sliders.firstWhere((s) => (s.value - 0.6).abs() < 0.001);
    fillSlider.onChanged!(0.4);
    await tester.pumpAndSettle();

    expect(picked, isNotNull);
    expect(picked!.a, closeTo(0.4, 0.01));
    expect(picked!.toARGB32() & 0x00FFFFFF, const Color(0xFF10B981).toARGB32() & 0x00FFFFFF,
        reason: 'only the alpha changes; the hue is left alone');
  });

  testWidgets('choosing a fill hue keeps the transparency already set',
      (tester) async {
    Color? picked;
    await _pumpFillPanel(tester,
        fillColor: const Color(0xFF10B981).withValues(alpha: 0.3),
        onFillColorChanged: (c) => picked = c);

    // Otherwise picking a colour silently snaps the fill back to fully opaque.
    // The tooltip drops the alpha, so the outline grid carries the same label.
    // The fill grid is rendered after it, so the last match is the fill swatch.
    final target = AppColors.palette.first;
    await tester.tap(
      find
          .byTooltip(
              '#${target.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}')
          .last,
    );
    await tester.pumpAndSettle();

    expect(picked, isNotNull);
    expect(picked!.a, closeTo(0.3, 0.01));
  });

  testWidgets('the fill swatches stay solid however transparent the fill is',
      (tester) async {
    // The transparency belongs to the mark being edited, not to the control
    // that picks its colour: painting the swatches tinted faded the whole row
    // out as the slider came down, until choosing a colour meant guessing
    // between near-identical ghosts.
    Color? picked;
    await _pumpFillPanel(tester,
        fillColor: AppColors.palette.first.withValues(alpha: 0.15),
        onFillColorChanged: (c) => picked = c);

    final circles = tester
        .widgetList<Container>(find.byType(Container))
        .map((c) => c.decoration)
        .whereType<BoxDecoration>()
        .where((d) => d.shape == BoxShape.circle)
        .map((d) => d.color)
        .whereType<Color>()
        .toList();

    for (final c in AppColors.palette) {
      expect(circles.map((d) => d.toARGB32()), contains(c.toARGB32()),
          reason: '$c must still be painted at full strength');
      expect(circles.where((d) => d.toARGB32() == c.withValues(alpha: 0.15).toARGB32()),
          isEmpty,
          reason: 'no swatch may be painted at the fill transparency');
    }

    // ...but picking one still applies the transparency that is set.
    await tester.tap(find.byTooltip(
      '#${AppColors.palette[1].toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}',
    ).last);
    await tester.pumpAndSettle();
    expect(picked, isNotNull);
    expect(picked!.a, closeTo(0.15, 0.01));
  });
}
