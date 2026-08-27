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
          startPoint: const Offset(200, 600),
          endPoint: const Offset(1400, 1000),
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

  test('annotations are burned in at their stored image pixels', () async {
    // 800x800 image in a 400x400 canvas: the image fills the canvas, so one
    // canvas unit is two image pixels. The annotation below is stored in image
    // pixels — which is what the editor persists — so it must land at exactly
    // (100,100)-(300,300) of the output. Reading it as canvas coordinates
    // instead doubles it to (200,200)-(600,600), and both assertions flip.
    final path = await _writeWhitePng(tempDir, 800, 800);

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

    // Inside the stored rect; outside the misread one.
    final inside = decoded.getPixel(150, 150);
    expect(
      inside.r,
      greaterThan(200),
      reason: 'annotation should be painted here',
    );
    expect(inside.g, lessThan(80));

    // Outside the stored rect; well inside the misread one.
    final outside = decoded.getPixel(500, 500);
    expect(
      outside.r,
      greaterThan(240),
      reason: 'annotation must not be scaled up by the canvas factor',
    );
    expect(outside.g, greaterThan(240));
    expect(outside.b, greaterThan(240));
  });

  test('stroke width is burned in at its stored image-pixel weight', () async {
    // Same 2x projection. A 40 image-pixel stroke must stay 40 image pixels in
    // the export; treating the stored value as canvas units would draw it at
    // 80, which the outer probes catch.
    final path = await _writeWhitePng(tempDir, 800, 800);

    final bytes = await RenderService.renderFlattenedPng(
      imagePath: path,
      annotations: [
        Annotation(
          id: 'a',
          tool: CanvasTool.line,
          color: const Color(0xFFFF0000),
          strokeWidth: 40,
          startPoint: const Offset(100, 400),
          endPoint: const Offset(700, 400),
        ),
      ],
      canvasSize: const Size(400, 400),
    );

    final decoded = img.decodePng(bytes!)!;

    for (final dy in [-15, 0, 15]) {
      final p = decoded.getPixel(400, 400 + dy);
      expect(p.r, greaterThan(200), reason: 'stroke should cover dy=$dy');
      expect(p.g, lessThan(80), reason: 'stroke should cover dy=$dy');
    }
    for (final dy in [-30, 30]) {
      final p = decoded.getPixel(400, 400 + dy);
      expect(
        p.g,
        greaterThan(240),
        reason: 'a 40px stroke must not reach dy=$dy; it was scaled up',
      );
    }
  });

  test(
    'export with no annotations returns the original bytes untouched',
    () async {
      final path = await _writeWhitePng(tempDir, 120, 90);
      final original = await File(path).readAsBytes();

      final bytes = await RenderService.renderFlattenedPng(
        imagePath: path,
        annotations: const [],
        canvasSize: const Size(400, 400),
      );

      expect(bytes, equals(original));
    },
  );

  test('pixelate blur actually replaces the underlying pixels', () async {
    // Half-black / half-white source: a mosaic over the boundary must change
    // pixels that would otherwise be pure white.
    final image = img.Image(width: 400, height: 400);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    img.fillRect(
      image,
      x1: 0,
      y1: 0,
      x2: 199,
      y2: 399,
      color: img.ColorRgb8(0, 0, 0),
    );
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
    expect(
      redacted.r,
      greaterThan(200),
      reason: 'mosaic must discard the original pixels inside the region',
    );

    // Same column, outside the region -> untouched black.
    final untouched = decoded.getPixel(160, 380);
    expect(untouched.r, 0);
  });

  test('a letterboxed projection cancels its vertical offset', () async {
    // 800x400 image in a 400x260 canvas: contain fits the width, so the image
    // occupies a 400x200 band centred at y=30. scale is 2.0. The stored
    // annotation must still land at image (100,100)-(300,300); dropping the
    // `translate(-imageRect.top)` term shifts everything down by scale*30 =
    // 60 image pixels, which the two probes below straddle.
    final path = await _writeWhitePng(tempDir, 800, 400);

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
      canvasSize: const Size(400, 260),
    );

    final decoded = img.decodePng(bytes!)!;

    // Inside the stored rect, above the 60px-shifted one.
    final top = decoded.getPixel(200, 120);
    expect(top.r, greaterThan(200), reason: 'shape must start at image y=100');
    expect(top.g, lessThan(80));

    // Below the stored rect, inside the shifted one.
    final below = decoded.getPixel(200, 340);
    expect(
      below.g,
      greaterThan(240),
      reason: 'the letterbox offset must cancel, not shift the shape down',
    );
  });

  test('a letterboxed projection cancels its horizontal offset', () async {
    // Transposed: a 400x800 image in the same 400x260 canvas fits the height
    // instead, occupying a 130x260 band centred at x=135. Dropping the
    // `translate(-imageRect.left)` term shifts everything right by
    // scale*135 = 415 image pixels — clean off the 400px-wide image.
    final path = await _writeWhitePng(tempDir, 400, 800);

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
      canvasSize: const Size(400, 260),
    );

    final decoded = img.decodePng(bytes!)!;

    final inside = decoded.getPixel(200, 200);
    expect(
      inside.r,
      greaterThan(200),
      reason:
          'the letterbox offset must cancel, not push the shape off the '
          'right-hand edge',
    );
    expect(inside.g, lessThan(80));
  });

  test(
    'throws rather than silently dropping annotations on a zero canvas',
    () async {
      final path = await _writeWhitePng(tempDir, 200, 100);
      final annotations = [
        Annotation(
          id: 'a',
          tool: CanvasTool.shape,
          color: const Color(0xFFFF0000),
          strokeWidth: 4.0,
          startPoint: const Offset(10, 10),
          endPoint: const Offset(90, 60),
        ),
      ];

      expect(
        () => RenderService.renderFlattenedPng(
          imagePath: path,
          annotations: annotations,
          canvasSize: Size.zero,
        ),
        throwsA(isA<StateError>()),
      );
    },
  );

  test(
    'still returns original bytes when there is nothing to composite',
    () async {
      final path = await _writeWhitePng(tempDir, 200, 100);
      final bytes = await RenderService.renderFlattenedPng(
        imagePath: path,
        annotations: const [],
        canvasSize: Size.zero,
      );
      expect(bytes, isNotNull);
    },
  );

  test('returns null for a missing source file instead of throwing', () async {
    final bytes = await RenderService.renderFlattenedPng(
      imagePath: '${tempDir.path}/does_not_exist.png',
      annotations: const [],
      canvasSize: const Size(400, 400),
    );
    expect(bytes, isNull);
  });
}
