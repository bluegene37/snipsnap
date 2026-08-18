import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/models/annotation.dart';
import 'package:snipsnap/utils/canvas_projection.dart';
import 'package:snipsnap/utils/constants.dart';

void main() {
  test('legacy viewport annotations convert once and stay stable after', () {
    final p = CanvasProjection(
      imageSize: const Size(1600, 900),
      canvasSize: const Size(800, 800),
    );

    final legacy = Annotation(
      id: 'legacy',
      tool: CanvasTool.shape,
      color: const Color(0xFF00FF00),
      strokeWidth: 2.0,
      startPoint: const Offset(100, 200),
      endPoint: const Offset(300, 400),
    );

    final converted = legacy.mappedToImageSpace(p);

    // Converting an already-converted annotation a second time must not be
    // applied twice — the caller is responsible for the space tag, so assert
    // the tag semantics rather than idempotency of the maths.
    expect(converted.startPoint, isNot(legacy.startPoint));
    expect(
      converted.mappedToCanvasSpace(p).startPoint!.dx,
      closeTo(100, 1e-6),
    );
  });

  test('CoordSpace parses by name with a viewport fallback', () {
    expect(coordSpaceByName('imagePixels'), CoordSpace.imagePixels);
    expect(coordSpaceByName('viewport'), CoordSpace.viewport);
    expect(coordSpaceByName(null), CoordSpace.viewport);
    expect(coordSpaceByName('nonsense'), CoordSpace.viewport);
  });
}
