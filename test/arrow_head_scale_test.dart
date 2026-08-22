import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/models/annotation.dart';
import 'package:snipsnap/utils/constants.dart';
import 'package:snipsnap/views/components/annotation_renderer.dart';

Annotation _arrow({required double strokeWidth, double length = 400}) => Annotation(
      id: 'a',
      tool: CanvasTool.arrow,
      color: const Color(0xFF000000),
      strokeWidth: strokeWidth,
      startPoint: const Offset(100, 300),
      endPoint: Offset(100 + length, 300),
    );

void main() {
  test('the head always flares wider than the shaft it terminates', () {
    // The report: thickening an arrow grew the body but not the point, until
    // the body was wider than the head and swallowed it. The head length used
    // to be clamped at half the arrow's span, so past a stroke weight of
    // span/8 it stopped growing while the shaft did not.
    for (final strokeWidth in const [2.0, 8.0, 20.0, 60.0, 120.0, 240.0]) {
      final head = AnnotationRenderer.arrowHead(_arrow(strokeWidth: strokeWidth));
      expect(head.halfWidth, greaterThan(strokeWidth / 2),
          reason: 'at stroke $strokeWidth the head must still be the widest '
              'part of the arrow');
    }
  });

  test('head and shaft keep a constant ratio as the arrow thickens', () {
    // "Behave like it was 1 item": doubling the weight doubles the head.
    final thin = AnnotationRenderer.arrowHead(_arrow(strokeWidth: 10));
    final thick = AnnotationRenderer.arrowHead(_arrow(strokeWidth: 20));

    expect(thick.length / thin.length, closeTo(2.0, 0.01));
    expect(thick.halfWidth / thin.halfWidth, closeTo(2.0, 0.01));
  });

  test('a head too big for a short arrow shrinks on both axes together', () {
    // The guard that stops a stubby arrow being all point must not distort it:
    // scaling only the length would flatten the head into a chevron.
    final head = AnnotationRenderer.arrowHead(_arrow(strokeWidth: 60, length: 80));

    expect(head.length, lessThanOrEqualTo(80 * 0.8 + 0.001));
    expect(head.halfWidth / head.length,
        closeTo(AnnotationRenderer.arrowHeadAspect, 0.001),
        reason: 'the head keeps its shape when it is scaled down');
  });

  test('the selection bounds contain the head, not just the shaft', () {
    // Without this the guide sits inside the arrow point, and the resize maths
    // that reads its extents under-reports how wide the mark really is.
    final arrow = _arrow(strokeWidth: 40);
    final head = AnnotationRenderer.arrowHead(arrow);
    final bounds = AnnotationRenderer.boundingRect(arrow);

    expect(bounds.top, lessThanOrEqualTo(300 - head.halfWidth + 0.001));
    expect(bounds.bottom, greaterThanOrEqualTo(300 + head.halfWidth - 0.001));
    expect(bounds.right, greaterThanOrEqualTo(500 - 0.001),
        reason: 'the tip is still the far edge');
  });

  test('a double arrow is bounded by both of its heads', () {
    final arrow = _arrow(strokeWidth: 40).copyWith(isDoubleArrow: true);
    final head = AnnotationRenderer.arrowHead(arrow);
    final bounds = AnnotationRenderer.boundingRect(arrow);

    expect(bounds.left, lessThanOrEqualTo(100 + 0.001));
    expect(bounds.top, lessThanOrEqualTo(300 - head.halfWidth + 0.001));
  });

  test('resizing accounts for how fast an arrow grows per unit of weight', () {
    // The arrow's width across its axis is its head, which is
    // 4 x 0.45 x 2 = 3.6 times the stroke weight. Resizing divides by this, so
    // a drag asking for n pixels of height gets n rather than 3.6n.
    expect(AnnotationRenderer.acrossExtentPerStrokeWidth(CanvasTool.arrow),
        closeTo(3.6, 0.001));
    expect(AnnotationRenderer.acrossExtentPerStrokeWidth(CanvasTool.line), 1.0);
  });
}
