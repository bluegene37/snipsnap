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

    test('applying convertLegacyAnnotationsChecked a second time over its own '
        'output double-scales the coordinates — the function has no way to '
        'know an annotation is already in image-pixel space, which is '
        'exactly why every call site must gate on a needs-conversion flag '
        'and never call this twice', () {
      const imageSize = Size(2000, 2000);
      const canvasSize = Size(1000, 1000);

      final first = convertLegacyAnnotationsChecked(
        annotations: [ann(const Offset(100, 100))],
        imageSize: imageSize,
        canvasSize: canvasSize,
      );
      expect(first.converted, isTrue);
      expect(first.annotations.single.startPoint!.dx, closeTo(200, 1e-6));
      expect(first.annotations.single.strokeWidth, closeTo(4.0, 1e-6));

      // Feed the already-converted output back in under the same projection,
      // as an ungated caller would. This must NOT be a no-op: it re-applies
      // the 2x scale on top of the first pass, landing at 4x the original —
      // proof that the pure function offers no built-in idempotency, so the
      // caller-side gate (check the flag before calling, clear it only once)
      // is load-bearing, not defensive boilerplate.
      final second = convertLegacyAnnotationsChecked(
        annotations: first.annotations,
        imageSize: imageSize,
        canvasSize: canvasSize,
      );
      expect(second.converted, isTrue);
      expect(second.annotations.single.startPoint!.dx, closeTo(400, 1e-6));
      expect(second.annotations.single.strokeWidth, closeTo(8.0, 1e-6));
    });
  });
}
