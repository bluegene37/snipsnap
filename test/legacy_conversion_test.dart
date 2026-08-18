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

  group('convertLegacyAnnotationsChecked', () {
    test('a valid projection converts and reports converted: true', () {
      final result = convertLegacyAnnotationsChecked(
        annotations: [ann(const Offset(100, 100))],
        imageSize: const Size(2000, 2000),
        canvasSize: const Size(1000, 1000),
      );
      expect(result.converted, isTrue);
      expect(result.annotations.single.startPoint!.dx, closeTo(200, 1e-6));
      expect(result.annotations.single.strokeWidth, closeTo(4.0, 1e-6));
    });

    test('an invalid projection (Size.zero image) returns input unchanged '
        'and reports converted: false', () {
      final input = [ann(const Offset(100, 100))];
      final result = convertLegacyAnnotationsChecked(
        annotations: input,
        imageSize: Size.zero,
        canvasSize: const Size(1000, 1000),
      );
      expect(result.converted, isFalse);
      expect(result.annotations, same(input));
      expect(result.annotations.single.startPoint, const Offset(100, 100));
    });

    test(
        'a second conversion of already-converted output is not applied when '
        'the caller gates on the converted/needs-conversion flag, guarding '
        'against double-scaling', () {
      // Mirrors the real call site (_convertActiveCaptureAnnotations): only
      // invoke the checked conversion while a "needs conversion" flag is
      // set, and only clear that flag once `converted` comes back true. A
      // second pass must then be skipped entirely rather than re-scaling
      // already-converted (image-pixel) coordinates.
      const imageSize = Size(2000, 2000);
      const canvasSize = Size(1000, 1000);

      var needsConversion = true;
      var annotations = [ann(const Offset(100, 100))];

      if (needsConversion) {
        final result = convertLegacyAnnotationsChecked(
          annotations: annotations,
          imageSize: imageSize,
          canvasSize: canvasSize,
        );
        if (result.converted) {
          annotations = result.annotations;
          needsConversion = false;
        }
      }
      expect(annotations.single.startPoint!.dx, closeTo(200, 1e-6));

      // Second pass over the same annotations: the flag is now false, so a
      // correctly-gated caller never calls convertLegacyAnnotationsChecked
      // again, and the coordinates must be exactly what the first pass
      // produced — not scaled a second time.
      if (needsConversion) {
        final result = convertLegacyAnnotationsChecked(
          annotations: annotations,
          imageSize: imageSize,
          canvasSize: canvasSize,
        );
        annotations = result.annotations;
      }
      expect(annotations.single.startPoint!.dx, closeTo(200, 1e-6));
    });
  });
}
