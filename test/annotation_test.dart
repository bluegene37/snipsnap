import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/models/annotation.dart';
import 'package:snipsnap/services/render_service.dart';
import 'package:snipsnap/utils/canvas_projection.dart';
import 'package:snipsnap/utils/constants.dart';
import 'package:snipsnap/views/components/annotation_renderer.dart';

Annotation _rect({
  Offset start = const Offset(100, 100),
  Offset end = const Offset(200, 160),
  bool fill = false,
  double strokeWidth = 4.0,
  double rotation = 0.0,
  ShapeKind kind = ShapeKind.rectangle,
}) {
  return Annotation(
    id: 'r1',
    tool: CanvasTool.shape,
    color: Colors.red,
    strokeWidth: strokeWidth,
    startPoint: start,
    endPoint: end,
    fill: fill,
    rotation: rotation,
    shapeKind: kind,
    // Square corners keep the geometry assertions exact.
    borderRadius: 0,
  );
}

void main() {
  group('Annotation model', () {
    test('copyWith can clear nullable colours via explicit null', () {
      final ann = _rect().copyWith(fillColor: Colors.blue, backgroundColor: Colors.black);
      expect(ann.fillColor, Colors.blue);

      final cleared = ann.copyWith(fillColor: null);
      expect(cleared.fillColor, isNull);
      // Fields not mentioned must survive.
      expect(cleared.backgroundColor, Colors.black);
    });

    test('copyWith without an argument leaves nullable colours untouched', () {
      final ann = _rect().copyWith(fillColor: Colors.blue);
      expect(ann.copyWith(strokeWidth: 9).fillColor, Colors.blue);
    });

    test('value equality compares geometry, not identity', () {
      final a = _rect();
      final b = _rect();
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(_rect(end: const Offset(201, 160)))));
    });

    test('props round-trip through JSON preserves every extra property', () {
      final original = _rect().copyWith(
        borderRadius: 17.5,
        lineStyle: LineStyle.dashed,
        blurType: BlurType.pixelate,
        blurStrength: 33.0,
        isDoubleArrow: true,
        hasShadow: true,
        rotation: 0.75,
        fillColor: const Color(0xFF123456),
        backgroundColor: const Color(0xAA654321),
      );

      final encoded = jsonEncode(original.toPropsJson());
      final restored = _rect().withPropsJson(jsonDecode(encoded) as Map<String, dynamic>);

      expect(restored.borderRadius, 17.5);
      expect(restored.lineStyle, LineStyle.dashed);
      expect(restored.blurType, BlurType.pixelate);
      expect(restored.blurStrength, 33.0);
      expect(restored.isDoubleArrow, isTrue);
      expect(restored.hasShadow, isTrue);
      expect(restored.rotation, 0.75);
      expect(restored.fillColor, const Color(0xFF123456));
      expect(restored.backgroundColor, const Color(0xAA654321));
    });

    test('translated moves every geometric component', () {
      final pen = Annotation(
        id: 'p',
        tool: CanvasTool.pen,
        color: Colors.red,
        points: const [Offset(0, 0), Offset(10, 10)],
      );
      final moved = pen.translated(const Offset(5, -5));
      expect(moved.points, [const Offset(5, -5), const Offset(15, 5)]);
    });

    test('opacity and blur strength are clamped to valid ranges', () {
      expect(_rect().copyWith(opacity: 4.0).opacity, 1.0);
      expect(_rect().copyWith(opacity: -1.0).opacity, 0.0);
      // The ceiling rejects an absurd sigma; it is deliberately far above any
      // value the slider can produce once scaled into image pixels, because a
      // display-space bound here silently ate the top of the slider's travel.
      expect(_rect().copyWith(blurStrength: 900).blurStrength, 900.0);
      expect(
        _rect().copyWith(blurStrength: 99999).blurStrength,
        Annotation.maxBlurStrength,
      );
      expect(_rect().copyWith(blurStrength: 0.0).blurStrength, 1.0);
    });
  });

  group('AnnotationRenderer geometry', () {
    test('hollow shapes are grabbable on the outline but not through the middle', () {
      final ann = _rect(); // 100,100 -> 200,160
      expect(AnnotationRenderer.hitTest(ann, const Offset(100, 130)), isTrue, reason: 'left edge');
      expect(AnnotationRenderer.hitTest(ann, const Offset(150, 130)), isFalse,
          reason: 'hollow centre must let clicks through to items underneath');
    });

    test('filled shapes are grabbable anywhere inside', () {
      final ann = _rect(fill: true);
      expect(AnnotationRenderer.hitTest(ann, const Offset(150, 130)), isTrue);
      expect(AnnotationRenderer.hitTest(ann, const Offset(400, 400)), isFalse);
    });

    test('hit testing follows the shape after rotation', () {
      // A wide, short rectangle rotated 90° becomes tall and narrow.
      final ann = _rect(
        start: const Offset(100, 140),
        end: const Offset(300, 160),
        fill: true,
        rotation: math.pi / 2,
      );

      // Point above the centre: outside the un-rotated box, inside the rotated one.
      expect(AnnotationRenderer.hitTest(ann, const Offset(200, 80)), isTrue);
      // Point to the side: inside the un-rotated box, outside the rotated one.
      expect(AnnotationRenderer.hitTest(ann, const Offset(295, 150)), isFalse);
    });

    test('local/canvas space conversions are inverses', () {
      final ann = _rect(rotation: 0.9);
      const probe = Offset(133, 121);
      final round = AnnotationRenderer.toCanvasSpace(ann, AnnotationRenderer.toLocalSpace(ann, probe));
      expect(round.dx, closeTo(probe.dx, 1e-9));
      expect(round.dy, closeTo(probe.dy, 1e-9));
    });

    test('freehand bounds include the stroke width', () {
      final pen = Annotation(
        id: 'p',
        tool: CanvasTool.pen,
        color: Colors.red,
        strokeWidth: 10,
        points: const [Offset(50, 50), Offset(80, 90)],
      );
      final bounds = AnnotationRenderer.boundingRect(pen);
      expect(bounds.left, 45);
      expect(bounds.right, 85);
    });

    test('every user-selectable tool produces a non-empty bounding box', () {
      // Guards against a tool being added to the sidebar but never given
      // geometry — the bug that made the ruler invisible.
      const drawable = [
        CanvasTool.pen,
        CanvasTool.line,
        CanvasTool.arrow,
        CanvasTool.shape,
        CanvasTool.highlight,
        CanvasTool.text,
        CanvasTool.stepMarker,
        CanvasTool.blur,
        CanvasTool.ruler,
      ];

      for (final tool in drawable) {
        final ann = Annotation(
          id: tool.name,
          tool: tool,
          color: Colors.red,
          text: 'x',
          stepNumber: 1,
          startPoint: const Offset(20, 20),
          endPoint: const Offset(120, 90),
          points: const [Offset(20, 20), Offset(120, 90)],
        );
        final bounds = AnnotationRenderer.boundingRect(ann);
        expect(bounds, isNot(Rect.zero), reason: '$tool has no bounds');
        expect(bounds.width > 0 || bounds.height > 0, isTrue, reason: '$tool has empty bounds');
      }
    });
  });

  group('Shape tool', () {
    test('every shape kind produces a closed path inside the drag rectangle', () {
      for (final kind in ShapeKind.values) {
        final ann = _rect(
          start: const Offset(40, 40),
          end: const Offset(240, 180),
          kind: kind,
        );
        final bounds = AnnotationRenderer.shapePath(ann).getBounds();
        expect(bounds.isEmpty, isFalse, reason: '$kind produced an empty path');
        // Inscribed: never larger than the rectangle the user dragged.
        expect(bounds.left, greaterThanOrEqualTo(39.5), reason: '$kind overflows left');
        expect(bounds.top, greaterThanOrEqualTo(39.5), reason: '$kind overflows top');
        expect(bounds.right, lessThanOrEqualTo(240.5), reason: '$kind overflows right');
        expect(bounds.bottom, lessThanOrEqualTo(180.5), reason: '$kind overflows bottom');
      }
    });

    test('a degenerate drag yields an empty path rather than throwing', () {
      for (final kind in ShapeKind.values) {
        final ann = _rect(start: const Offset(10, 10), end: const Offset(10, 10), kind: kind);
        expect(AnnotationRenderer.shapePath(ann).getBounds().isEmpty, isTrue);
      }
    });

    test('hit testing respects the actual outline, not just the bounding box', () {
      // A filled triangle: the top-left corner of its bounding box is outside
      // the triangle itself.
      final triangle = _rect(
        start: const Offset(0, 0),
        end: const Offset(200, 200),
        fill: true,
        kind: ShapeKind.triangle,
      );
      expect(AnnotationRenderer.hitTest(triangle, const Offset(100, 150)), isTrue,
          reason: 'inside the triangle');
      expect(AnnotationRenderer.hitTest(triangle, const Offset(15, 15)), isFalse,
          reason: 'in the bounding box but outside the triangle');
    });

    test('hollow shapes are grabbable along a curved outline', () {
      final ellipse = _rect(
        start: const Offset(0, 0),
        end: const Offset(200, 200),
        kind: ShapeKind.ellipse,
      );
      // Rightmost point of the ellipse.
      expect(AnnotationRenderer.hitTest(ellipse, const Offset(200, 100)), isTrue);
      // Dead centre: hollow, so the click passes through.
      expect(AnnotationRenderer.hitTest(ellipse, const Offset(100, 100)), isFalse);
    });

    test('shape kind survives a props JSON round-trip', () {
      final original = _rect(kind: ShapeKind.star);
      final restored = _rect().withPropsJson(
        jsonDecode(jsonEncode(original.toPropsJson())) as Map<String, dynamic>,
      );
      expect(restored.shapeKind, ShapeKind.star);
    });

    test('curved Bezier arrow round-trips controlPoint and computes curved bounds & hit-test', () {
      final arrow = Annotation(
        id: 'a1',
        tool: CanvasTool.arrow,
        color: Colors.red,
        startPoint: const Offset(0, 0),
        endPoint: const Offset(100, 0),
        controlPoint: const Offset(50, 50),
        strokeWidth: 4.0,
      );

      // JSON props roundtrip
      final encoded = jsonEncode(arrow.toPropsJson());
      final restored = arrow.withPropsJson(jsonDecode(encoded) as Map<String, dynamic>);
      expect(restored.controlPoint, const Offset(50, 50));

      // Translated
      final moved = arrow.translated(const Offset(10, 20));
      expect(moved.controlPoint, const Offset(60, 70));

      // Bounding box includes the arc apex
      final bounds = AnnotationRenderer.boundingRect(arrow);
      expect(bounds.bottom, greaterThan(25.0));

      // Hit testing hits the curved arc near apex
      expect(AnnotationRenderer.hitTest(arrow, const Offset(50, 25)), isTrue);
      // Straight line midpoint should not hit the curved arrow
      expect(AnnotationRenderer.hitTest(arrow, const Offset(50, 0)), isFalse);
    });

    test('solid blackout redaction bar survives JSON round-trip', () {
      final blur = Annotation(
        id: 'b1',
        tool: CanvasTool.blur,
        color: Colors.black,
        blurType: BlurType.solid,
        startPoint: const Offset(10, 10),
        endPoint: const Offset(100, 40),
      );

      final encoded = jsonEncode(blur.toPropsJson());
      final restored = blur.withPropsJson(jsonDecode(encoded) as Map<String, dynamic>);
      expect(restored.blurType, BlurType.solid);
    });
  });

  group('RenderService coordinate mapping', () {
    test('letterboxes a wide image inside a square canvas', () {
      final rect = RenderService.imageRectInCanvas(
        imageSize: const Size(1000, 500),
        canvasSize: const Size(400, 400),
      );
      expect(rect.width, 400);
      expect(rect.height, 200);
      expect(rect.top, 100);
      expect(rect.left, 0);
    });

    test('pillarboxes a tall image inside a wide canvas', () {
      final rect = RenderService.imageRectInCanvas(
        imageSize: const Size(500, 1000),
        canvasSize: const Size(400, 400),
      );
      expect(rect.height, 400);
      expect(rect.width, 200);
      expect(rect.left, 100);
    });

    test('returns an empty rect for degenerate sizes rather than NaN', () {
      expect(
        RenderService.imageRectInCanvas(
          imageSize: Size.zero,
          canvasSize: const Size(400, 400),
        ),
        Rect.zero,
      );
    });
  });

  group('coordinate space mapping', () {
    final projection = CanvasProjection(
      imageSize: const Size(2000, 1000),
      canvasSize: const Size(1000, 1000),
    );

    test('round-trips geometry and scalar dimensions', () {
      final original = Annotation(
        id: 'x',
        tool: CanvasTool.arrow,
        color: const Color(0xFFFF0000),
        strokeWidth: 4.0,
        fontSize: 18.0,
        borderRadius: 8.0,
        blurStrength: 14.0,
        startPoint: const Offset(100, 300),
        endPoint: const Offset(400, 600),
        controlPoint: const Offset(250, 400),
        points: const [Offset(10, 260), Offset(20, 270)],
        rect: const Rect.fromLTRB(100, 300, 400, 600),
      );

      final round = original
          .mappedToImageSpace(projection)
          .mappedToCanvasSpace(projection);

      expect(round.startPoint!.dx, closeTo(100, 1e-6));
      expect(round.startPoint!.dy, closeTo(300, 1e-6));
      expect(round.endPoint!.dy, closeTo(600, 1e-6));
      expect(round.controlPoint!.dx, closeTo(250, 1e-6));
      expect(round.points.first.dx, closeTo(10, 1e-6));
      expect(round.rect!.right, closeTo(400, 1e-6));
      expect(round.strokeWidth, closeTo(4.0, 1e-6));
      expect(round.fontSize, closeTo(18.0, 1e-6));
      expect(round.borderRadius, closeTo(8.0, 1e-6));
      expect(round.blurStrength, closeTo(14.0, 1e-6));
    });

    test('scales stroke width into image pixels', () {
      final ann = Annotation(
        id: 'x',
        tool: CanvasTool.line,
        color: const Color(0xFF000000),
        strokeWidth: 3.0,
        startPoint: const Offset(0, 250),
        endPoint: const Offset(500, 250),
      );
      // 2000px image fitted into 1000px canvas -> scale 2.0
      final inImage = ann.mappedToImageSpace(projection);
      expect(inImage.strokeWidth, closeTo(6.0, 1e-6));
      expect(inImage.startPoint!.dx, closeTo(0, 1e-6));
      expect(inImage.endPoint!.dx, closeTo(1000, 1e-6));
    });

    test('copyWith can explicitly clear endPoint and rect', () {
      final ann = Annotation(
        id: 'x',
        tool: CanvasTool.text,
        color: const Color(0xFF000000),
        startPoint: const Offset(1, 2),
        endPoint: const Offset(3, 4),
        rect: const Rect.fromLTRB(0, 0, 5, 5),
      );
      final cleared = ann.copyWith(endPoint: null, rect: null);
      expect(cleared.endPoint, isNull);
      expect(cleared.rect, isNull);
      expect(cleared.startPoint, const Offset(1, 2));
    });

    test('withPropsJson preserves an existing rect when the map has no rect key', () {
      final ann = Annotation(
        id: 'x',
        tool: CanvasTool.shape,
        color: const Color(0xFF000000),
        rect: const Rect.fromLTRB(10, 20, 30, 40),
      );
      final restored = ann.withPropsJson(const {'borderRadius': 3.0});
      expect(restored.rect, const Rect.fromLTRB(10, 20, 30, 40));
    });
  });

  group('ruler measurement', () {
    test('the badge reports image pixels, not display pixels', () {
      // A 3840x2160 capture shown in a 960x540 canvas is downscaled 4x, so a
      // ruler the user drags across 100 canvas pixels is measuring 400 pixels
      // of the actual screenshot. Reporting 100 would make the tool useless on
      // every Retina capture.
      final p = CanvasProjection(
        imageSize: const Size(3840, 2160),
        canvasSize: const Size(960, 540),
      );
      expect(p.scale, closeTo(4.0, 1e-9));

      final ruler = Annotation(
        id: 'r',
        tool: CanvasTool.ruler,
        color: const Color(0xFF000000),
        startPoint: const Offset(20, 30),
        endPoint: const Offset(120, 30),
      );

      expect(AnnotationRenderer.rulerLabel(ruler, p.scale), '400 px');
      // The unscaled reading is what the badge used to show.
      expect(AnnotationRenderer.rulerLabel(ruler, 1.0), '100 px');
    });

    test('an already image-space ruler is reported unscaled', () {
      // The exporter replays canvas-space geometry, but a caller painting
      // stored coordinates directly passes 1.0 and must get the raw length.
      final ruler = Annotation(
        id: 'r',
        tool: CanvasTool.ruler,
        color: const Color(0xFF000000),
        startPoint: const Offset(0, 0),
        endPoint: const Offset(300, 400),
      );
      expect(AnnotationRenderer.rulerLabel(ruler, 1.0), '500 px');
    });

    test('a ruler with no endpoint has no label', () {
      final ruler = Annotation(
        id: 'r',
        tool: CanvasTool.ruler,
        color: const Color(0xFF000000),
        startPoint: const Offset(0, 0),
      );
      expect(AnnotationRenderer.rulerLabel(ruler, 4.0), '');
    });
  });
}
