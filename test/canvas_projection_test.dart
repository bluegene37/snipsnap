import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/utils/canvas_projection.dart';

void main() {
  test('maps canvas points to image pixels through a letterboxed fit', () {
    // 1000x500 image inside an 800x800 canvas -> fits to 800x400, centred
    // vertically with 200px letterbox top and bottom. scale = 1000/800 = 1.25
    final p = CanvasProjection(
      imageSize: const Size(1000, 500),
      canvasSize: const Size(800, 800),
    );

    expect(p.isValid, isTrue);
    expect(p.scale, closeTo(1.25, 1e-9));
    expect(p.imageRect, const Rect.fromLTWH(0, 200, 800, 400));

    expect(p.toImage(const Offset(0, 200)), const Offset(0, 0));
    expect(p.toImage(const Offset(800, 600)), const Offset(1000, 500));
    expect(p.toImage(const Offset(400, 400)), const Offset(500, 250));
  });

  test('round-trips points at several viewport sizes', () {
    const imageSize = Size(1920, 1080);
    for (final canvas in const [
      Size(800, 600),
      Size(1440, 900),
      Size(300, 1200),
      Size(2000, 400),
    ]) {
      final p = CanvasProjection(imageSize: imageSize, canvasSize: canvas);
      for (final pt in const [
        Offset(0, 0),
        Offset(960, 540),
        Offset(1919, 1079),
      ]) {
        final round = p.toImage(p.toCanvas(pt));
        expect(round.dx, closeTo(pt.dx, 1e-6), reason: 'canvas=$canvas pt=$pt');
        expect(round.dy, closeTo(pt.dy, 1e-6), reason: 'canvas=$canvas pt=$pt');
      }
    }
  });

  test('scales lengths so stroke weights survive the round trip', () {
    final p = CanvasProjection(
      imageSize: const Size(3840, 2160),
      canvasSize: const Size(960, 540),
    );
    expect(p.scale, closeTo(4.0, 1e-9));
    expect(p.toImageLength(3.0), closeTo(12.0, 1e-9));
    expect(p.toCanvasLength(12.0), closeTo(3.0, 1e-9));
  });

  test('is invalid for empty sizes and never divides by zero', () {
    expect(
      CanvasProjection(
        imageSize: Size.zero,
        canvasSize: const Size(10, 10),
      ).isValid,
      isFalse,
    );
    expect(
      CanvasProjection(
        imageSize: const Size(10, 10),
        canvasSize: Size.zero,
      ).isValid,
      isFalse,
    );
    final invalid = CanvasProjection(
      imageSize: Size.zero,
      canvasSize: Size.zero,
    );
    expect(invalid.scale, 1.0);
    expect(invalid.toImage(const Offset(5, 5)), const Offset(5, 5));
  });
}
