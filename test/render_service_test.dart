import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:snipsnap/models/annotation.dart';
import 'package:snipsnap/services/render_service.dart';
import 'package:snipsnap/utils/constants.dart';

/// Writes a solid white [w]x[h] PNG to a temp file and returns its path.
Future<String> _writeWhitePng(Directory dir, int w, int h) async {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgb8(255, 255, 255));
  final path = '${dir.path}/source.png';
  await File(path).writeAsBytes(img.encodePng(image));
  return path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('snipsnap_render_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  test('flattened export keeps the source image native resolution', () async {
    // A 1600x1000 screenshot displayed in a 400x400 editor canvas must still
    // export at 1600x1000 — the old RepaintBoundary capture downsampled to the
    // viewport size.
    final path = await _writeWhitePng(tempDir, 1600, 1000);

    final bytes = await RenderService.renderFlattenedPng(
      imagePath: path,
      annotations: [
        Annotation(
          id: 'a',
          tool: CanvasTool.shape,
          color: Colors.red,
          fill: true,
          fillColor: Colors.red,
          borderRadius: 0,
          startPoint: const Offset(50, 150),
          endPoint: const Offset(350, 250),
        ),
      ],
      canvasSize: const Size(400, 400),
    );

    expect(bytes, isNotNull);
    final decoded = img.decodePng(bytes!);
    expect(decoded, isNotNull);
    expect(decoded!.width, 1600);
    expect(decoded.height, 1000);
  });

  test('annotations are composited into the exported pixels at the right place',
      () async {
    final path = await _writeWhitePng(tempDir, 800, 800);

    // Square image in a square canvas => the image fills the canvas 1:1 at 2x.
    final bytes = await RenderService.renderFlattenedPng(
      imagePath: path,
      annotations: [
        Annotation(
          id: 'a',
          tool: CanvasTool.shape,
          color: const Color(0xFFFF0000),
          fill: true,
          fillColor: const Color(0xFFFF0000),
          borderRadius: 0,
          strokeWidth: 1,
          startPoint: const Offset(100, 100),
          endPoint: const Offset(300, 300),
        ),
      ],
      canvasSize: const Size(400, 400),
    );

    final decoded = img.decodePng(bytes!)!;

    // Canvas (200,200) is the centre of the shape -> image pixel (400,400).
    final inside = decoded.getPixel(400, 400);
    expect(inside.r, greaterThan(200), reason: 'annotation should be painted here');
    expect(inside.g, lessThan(80));

    // Canvas (350,350) is outside the shape -> still white.
    final outside = decoded.getPixel(700, 700);
    expect(outside.r, greaterThan(240));
    expect(outside.g, greaterThan(240));
    expect(outside.b, greaterThan(240));
  });

  test('export with no annotations returns the original bytes untouched', () async {
    final path = await _writeWhitePng(tempDir, 120, 90);
    final original = await File(path).readAsBytes();

    final bytes = await RenderService.renderFlattenedPng(
      imagePath: path,
      annotations: const [],
      canvasSize: const Size(400, 400),
    );

    expect(bytes, equals(original));
  });

  test('pixelate blur actually replaces the underlying pixels', () async {
    // Half-black / half-white source: a mosaic over the boundary must change
    // pixels that would otherwise be pure white.
    final image = img.Image(width: 400, height: 400);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    img.fillRect(image, x1: 0, y1: 0, x2: 199, y2: 399, color: img.ColorRgb8(0, 0, 0));
    final path = '${tempDir.path}/split.png';
    await File(path).writeAsBytes(img.encodePng(image));

    // A 100px region with a 60px block size collapses to a single mosaic cell
    // sampled from its centre (x=200, the white side), so the black half
    // *inside* the region must be overwritten with white.
    final bytes = await RenderService.renderFlattenedPng(
      imagePath: path,
      annotations: [
        Annotation(
          id: 'b',
          tool: CanvasTool.blur,
          color: Colors.grey,
          blurType: BlurType.pixelate,
          blurStrength: 60,
          startPoint: const Offset(150, 150),
          endPoint: const Offset(250, 250),
        ),
      ],
      canvasSize: const Size(400, 400),
    );

    final decoded = img.decodePng(bytes!)!;

    // Was pure black, sits inside the mosaic region -> original pixel is gone.
    final redacted = decoded.getPixel(160, 200);
    expect(redacted.r, greaterThan(200),
        reason: 'mosaic must discard the original pixels inside the region');

    // Same column, outside the region -> untouched black.
    final untouched = decoded.getPixel(160, 380);
    expect(untouched.r, 0);
  });

  test('returns null for a missing source file instead of throwing', () async {
    final bytes = await RenderService.renderFlattenedPng(
      imagePath: '${tempDir.path}/does_not_exist.png',
      annotations: const [],
      canvasSize: const Size(400, 400),
    );
    expect(bytes, isNull);
  });
}
