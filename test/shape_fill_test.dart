import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:snipsnap/models/annotation.dart';
import 'package:snipsnap/services/render_service.dart';
import 'package:snipsnap/utils/constants.dart';

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

  test('the opacity slider is still the way to make a fill translucent',
      () async {
    // Solid by default does not mean solid always — opacity has to keep
    // working, or removing the hardcoded wash would have removed the only way
    // to see through a shape.
    final px = await renderAndSampleCentre(filledSquare(opacity: 0.5));

    expect(px.g, greaterThan(100),
        reason: 'half-opacity red over white must let white through');
    expect(px.g, lessThan(200));
  });
}
