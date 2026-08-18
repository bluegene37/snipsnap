import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/models/annotation.dart';
import 'package:snipsnap/utils/canvas_projection.dart';
import 'package:snipsnap/utils/constants.dart';

void main() {
  Annotation ann(Offset start) => Annotation(
        id: 's',
        tool: CanvasTool.line,
        color: const Color(0xFF000000),
        strokeWidth: 2.0,
        startPoint: start,
        endPoint: start + const Offset(50, 50),
      );

  test('converts viewport annotations into image pixels', () {
    final result = convertLegacyAnnotations(
      annotations: [ann(const Offset(100, 100))],
      imageSize: const Size(2000, 2000),
      canvasSize: const Size(1000, 1000),
    );
    expect(result.single.startPoint!.dx, closeTo(200, 1e-6));
    expect(result.single.strokeWidth, closeTo(4.0, 1e-6));
  });

  test('returns annotations untouched when the projection is invalid', () {
    final input = [ann(const Offset(100, 100))];
    final result = convertLegacyAnnotations(
      annotations: input,
      imageSize: Size.zero,
      canvasSize: const Size(1000, 1000),
    );
    expect(result.single.startPoint, const Offset(100, 100));
  });
}
