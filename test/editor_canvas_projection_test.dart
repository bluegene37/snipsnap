import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/models/annotation.dart';
import 'package:snipsnap/utils/canvas_projection.dart';
import 'package:snipsnap/utils/constants.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an annotation keeps its image position across viewport sizes', () {
    // Stored in image pixels: a line across the middle of a 1600x900 image.
    final stored = Annotation(
      id: 'a',
      tool: CanvasTool.line,
      color: const Color(0xFF000000),
      strokeWidth: 8.0,
      startPoint: const Offset(800, 450),
      endPoint: const Offset(1200, 450),
    );

    const imageSize = Size(1600, 900);
    Offset canvasStartFor(Size canvas) {
      final p = CanvasProjection(imageSize: imageSize, canvasSize: canvas);
      return p.toImage(stored.mappedToCanvasSpace(p).startPoint!);
    }

    // Whatever the window size, converting to canvas and back lands on the
    // same image pixel. This is the drift regression.
    for (final canvas in const [
      Size(800, 600),
      Size(1600, 900),
      Size(400, 1000),
    ]) {
      final round = canvasStartFor(canvas);
      expect(round.dx, closeTo(800, 1e-6), reason: 'canvas=$canvas');
      expect(round.dy, closeTo(450, 1e-6), reason: 'canvas=$canvas');
    }
  });
}
