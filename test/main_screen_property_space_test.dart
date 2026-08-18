import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/models/annotation.dart';
import 'package:snipsnap/utils/canvas_projection.dart';
import 'package:snipsnap/utils/constants.dart';

/// Returns the body of a 2-space-indented method in [source].
///
/// Unlike the helper in `editor_canvas_projection_test.dart` this one skips
/// past the signature's own closing `) {` first, so a method whose parameter
/// list spans several lines is not truncated at `\n  }) {`.
String _bodyOf(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, isNot(-1), reason: 'could not find `$signature` in the source');
  final bodyStart = source.indexOf(') {\n', start);
  expect(bodyStart, isNot(-1), reason: 'could not find the body of `$signature`');
  final end = source.indexOf('\n  }', bodyStart);
  expect(end, isNot(-1), reason: 'could not find the end of `$signature`');
  return source.substring(bodyStart, end);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A 3024x1890 Retina capture in a 1200x750 editor canvas: 2.52 image pixels
  // per canvas pixel. The aspect ratios match, so there is no letterbox and the
  // arithmetic below is exact.
  final projection = CanvasProjection(
    imageSize: const Size(3024, 1890),
    canvasSize: const Size(1200, 750),
  );

  Annotation arrow({double strokeWidth = 10.0}) => Annotation(
        id: 'a',
        tool: CanvasTool.arrow,
        color: const Color(0xFFFF0000),
        strokeWidth: strokeWidth,
        fontSize: 20.0,
        borderRadius: 16.0,
        blurStrength: 20.0,
        startPoint: const Offset(100, 100),
        endPoint: const Offset(900, 700),
      );

  group('toolbar property writes', () {
    test('slider values land in the stored annotation as image pixels', () {
      expect(projection.scale, closeTo(2.52, 1e-9));

      // The stored stroke is 10 image pixels, which the toolbar correctly shows
      // as 4. Dragging the slider to 6 must store 15.12 — bigger than what was
      // there. Writing the raw 6 makes the stroke *thinner* as the user drags
      // the slider up, which is the bug this guards.
      final stored = arrow();
      final updated = stored.withCanvasSpaceScalars(projection, strokeWidth: 6);

      expect(updated.strokeWidth, closeTo(15.12, 1e-9));
      expect(
        updated.strokeWidth,
        greaterThan(stored.strokeWidth),
        reason: 'raising the slider must not shrink the rendered stroke',
      );
    });

    test('all four scale-dependent scalars are converted', () {
      final updated = arrow().withCanvasSpaceScalars(
        projection,
        strokeWidth: 4,
        fontSize: 18,
        borderRadius: 8,
        blurStrength: 10,
      );
      expect(updated.strokeWidth, closeTo(4 * 2.52, 1e-9));
      expect(updated.fontSize, closeTo(18 * 2.52, 1e-9));
      expect(updated.borderRadius, closeTo(8 * 2.52, 1e-9));
      expect(updated.blurStrength, closeTo(10 * 2.52, 1e-9));
    });

    test('omitted scalars are left untouched', () {
      final stored = arrow();
      final updated = stored.withCanvasSpaceScalars(projection, strokeWidth: 6);
      expect(updated.fontSize, stored.fontSize);
      expect(updated.borderRadius, stored.borderRadius);
      expect(updated.blurStrength, stored.blurStrength);
      // Geometry is not a slider property and must not move.
      expect(updated.startPoint, stored.startPoint);
      expect(updated.endPoint, stored.endPoint);
    });

    test('a degenerate projection declines the write instead of corrupting it',
        () {
      final stored = arrow();
      // Canvas not laid out yet: canvas units cannot be converted, so the
      // stored image-space values must survive unchanged rather than be
      // overwritten with display numbers.
      final noCanvas = CanvasProjection(
        imageSize: const Size(3024, 1890),
        canvasSize: Size.zero,
      );
      expect(stored.withCanvasSpaceScalars(noCanvas, strokeWidth: 6), stored);
      expect(stored.withCanvasSpaceScalars(null, strokeWidth: 6), stored);
    });
  });

  // ---------------------------------------------------------------------------
  // Call-site invariant.
  //
  // Source-level for the same reason as the Task 6 checks: `_updateActiveTool
  // Property` lives on a State whose build tree contains `Image.file`, which
  // hangs `flutter_tester` indefinitely, so it cannot be driven by testWidgets.
  // The conversion itself is covered by the runtime tests above; this catches
  // the regression that actually happened — the scalars being handed straight
  // to `copyWith` alongside the scale-independent properties.
  // ---------------------------------------------------------------------------

  group('MainScreen writes slider values through the projection', () {
    late String body;

    setUpAll(() {
      body = _bodyOf(
        File('lib/views/main_screen.dart').readAsStringSync(),
        'void _updateActiveToolProperty({',
      );
    });

    test('the annotation write goes through withCanvasSpaceScalars', () {
      expect(
        body,
        contains('withCanvasSpaceScalars('),
        reason: 'the toolbar sliders are in canvas units and _annotations is '
            'in image pixels; writing them directly stores display numbers',
      );
      expect(body, contains('_activeProjection'));
    });

    for (final scalar in const [
      'strokeWidth',
      'fontSize',
      'borderRadius',
      'blurStrength',
    ]) {
      test('$scalar is not written straight into the annotation copyWith', () {
        // `copyWith` is called once with the scale-independent properties and
        // is followed by `withCanvasSpaceScalars`; the four lengths must appear
        // only after that call.
        final conversionAt = body.indexOf('withCanvasSpaceScalars(');
        final annotationWriteAt = body.indexOf('_annotations[idx]');
        expect(annotationWriteAt, isNot(-1));
        expect(conversionAt, greaterThan(annotationWriteAt));

        final unconverted = body.substring(annotationWriteAt, conversionAt);
        expect(
          unconverted,
          isNot(contains('$scalar:')),
          reason: '$scalar is a length: passing it to copyWith stores a canvas '
              'value in image-pixel storage',
        );
      });
    }
  });
}
