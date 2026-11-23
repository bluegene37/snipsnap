// Gene - Nov, 20, 2026: Added dart:collection for bounded LRU TextPainter layout caching.
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../models/annotation.dart';
import '../../utils/constants.dart';
// Gene - Nov, 23, 2026: Import SnipTheme so selection chrome and measurement HUD follow the Skeleton monochrome contrast system.
import '../../utils/snip_theme.dart';

/// Single source of truth for annotation geometry and painting.
///
/// Both the interactive canvas painter and the offscreen export renderer draw
/// through this class, so what the user sees on screen is exactly what gets
/// written to the exported PNG.
class AnnotationRenderer {
  const AnnotationRenderer._();

  static const double hitPadding = 10.0;

  /// Two-point marks whose extent includes their stroke weight.
  static const Set<CanvasTool> _strokeBoundedTools = {CanvasTool.line};

  /// An arrow head reaches this multiple of the stroke weight back from the
  /// tip, and flares [arrowHeadAspect] of that to each side.
  static const double arrowHeadLengthMultiplier = 4.0;
  static const double arrowHeadAspect = 0.45;
  static const double arrowHeadMinLength = 12.0;

  /// The head geometry for a straight arrow, shared by the painter and by
  /// [boundingRect] so the two can never disagree about how big the head is.
  ///
  /// Both dimensions scale with the stroke weight, and a head too long for a
  /// short arrow is scaled down on *both* axes together. Clamping only the
  /// length — as this used to, at half the arrow's span — left the head frozen
  /// while the shaft went on thickening, until the body was wider than the
  /// point it was supposed to be attached to.
  // Gene - Nov, 20, 2026: Proportional arrow head & ruler cap floors so zoomed-in strokes don't keep giant 1x minimum dimensions.
  static double _safeScale(double s) => s > 1e-4 ? s : 1.0;

  static ({double length, double halfWidth}) arrowHead(Annotation ann) {
    final start = ann.startPoint;
    final end = ann.endPoint;
    if (start == null || end == null) return (length: 0, halfWidth: 0);

    // Old:
    // var length = math.max(
    //   arrowHeadMinLength,
    //   ann.strokeWidth * arrowHeadLengthMultiplier,
    // );
    var length = math.max(0.5, ann.strokeWidth * arrowHeadLengthMultiplier);
    var halfWidth = length * arrowHeadAspect;

    final maxLength = (end - start).distance * 0.8;
    if (maxLength > 0 && length > maxLength) {
      final scale = maxLength / length;
      length *= scale;
      halfWidth *= scale;
    }
    return (length: length, halfWidth: halfWidth);
  }

  /// How far a ruler's end caps and ticks reach on each side of its line, as a
  /// multiple of the stroke weight. Ticks have to stay visible as the line
  /// thickens, which is why they scale rather than sit at a fixed size.
  static const double rulerCapMultiplier = 3.5;
  static const double rulerMinCapHalf = 6.0;

  // Old:
  // static double rulerCapHalf(Annotation ann) =>
  //     math.max(rulerMinCapHalf, ann.strokeWidth * rulerCapMultiplier);
  static double rulerCapHalf(Annotation ann) =>
      math.max(0.5, ann.strokeWidth * rulerCapMultiplier);

  /// How much a mark's extent *across* its own axis grows per unit of stroke
  /// weight.
  ///
  /// One for anything drawn as a plain stroke. A ruler is the exception: its
  /// caps reach [rulerCapMultiplier] times the weight on each side of the line,
  /// so a ruler grows eight times as fast as its stroke width. Resizing divides
  /// by this, or a drag that should have added 80px of height added 640 — the
  /// ruler "expanding extremely".
  static double acrossExtentPerStrokeWidth(CanvasTool tool) => switch (tool) {
    CanvasTool.ruler => 1.0 + rulerCapMultiplier * 2,
    // An arrow is as wide as its head, which flares well past the shaft —
    // plus the half-weight `boundingRect` pads on each side, the same
    // term the ruler's own figure carries.
    CanvasTool.arrow => 1.0 + arrowHeadLengthMultiplier * arrowHeadAspect * 2,
    _ => 1.0,
  };

  static const double selectionInset = 8.0;
  static const double rotationHandleGap = 24.0;
  static const double handleHitRadius = 14.0;

  // Gene - Nov, 23, 2026: Added tool handle capability helpers, Bezier curve-apex math, step ring geometry, and rotated chrome bounds.
  static bool isLinearEndpointTool(CanvasTool tool) =>
      tool == CanvasTool.arrow ||
      tool == CanvasTool.line ||
      tool == CanvasTool.ruler;

  static bool supportsRotation(CanvasTool tool) =>
      !isLinearEndpointTool(tool) &&
      tool != CanvasTool.stepMarker &&
      tool != CanvasTool.blur;

  /// Actual midpoint on the quadratic Bezier curve (the visible curve apex).
  static Offset arrowCurveApex(Annotation ann) {
    final start = ann.startPoint;
    final end = ann.endPoint;
    if (start == null || end == null) return Offset.zero;
    final cp = ann.controlPoint;
    if (cp == null) return (start + end) / 2;
    return _bezierPoint(start, cp, end, 0.5);
  }

  /// Derives the quadratic Bezier control point whose midpoint lies at [apex].
  static Offset controlPointForApex(Offset start, Offset end, Offset apex) =>
      apex * 2.0 - (start + end) / 2.0;

  static double stepSelectionRingRadius(
    Annotation ann, {
    double viewScale = 1.0,
  }) => _stepRadius(ann) + 5.0 / _safeScale(viewScale);

  static Offset stepScaleHandlePosition(
    Annotation ann, {
    double viewScale = 1.0,
  }) {
    final center = ann.startPoint;
    if (center == null) return Offset.zero;
    final r = stepSelectionRingRadius(ann, viewScale: viewScale);
    return center + Offset(r * math.sqrt1_2, r * math.sqrt1_2);
  }

  /// Axis-aligned canvas-space bounds enclosing the drawn selection chrome.
  static Rect rotatedSelectionBounds(
    Annotation ann, {
    double viewScale = 1.0,
  }) {
    final s = _safeScale(viewScale);
    final Rect base;
    if (ann.tool == CanvasTool.stepMarker && ann.startPoint != null) {
      base = Rect.fromCircle(
        center: ann.startPoint!,
        radius: stepSelectionRingRadius(ann, viewScale: s),
      );
    } else {
      base = selectionRect(ann, viewScale: s);
    }
    if (base == Rect.zero) return Rect.zero;
    if (ann.rotation == 0.0) return base;
    final corners = [
      toCanvasSpace(ann, base.topLeft),
      toCanvasSpace(ann, base.topRight),
      toCanvasSpace(ann, base.bottomLeft),
      toCanvasSpace(ann, base.bottomRight),
    ];
    return _boundsThrough(corners, 0.0);
  }

  static ({double length, double halfWidth}) _curvedArrowHead(
    Annotation ann,
    double pathLength,
  ) {
    var length = math.max(0.5, ann.strokeWidth * arrowHeadLengthMultiplier);
    var halfWidth = length * arrowHeadAspect;
    final maxLength = pathLength * 0.8;
    if (maxLength > 0 && length > maxLength) {
      final scale = maxLength / length;
      length *= scale;
      halfWidth *= scale;
    }
    return (length: length, halfWidth: halfWidth);
  }

  // ---------------------------------------------------------------------------
  // Geometry
  // ---------------------------------------------------------------------------

  /// Axis-aligned bounds of the annotation *before* rotation is applied.
  static Rect boundingRect(Annotation ann) {
    switch (ann.tool) {
      case CanvasTool.pen:
      case CanvasTool.highlight:
        if (ann.points.isEmpty) return Rect.zero;
        double minX = ann.points.first.dx;
        double maxX = ann.points.first.dx;
        double minY = ann.points.first.dy;
        double maxY = ann.points.first.dy;
        for (final p in ann.points) {
          if (p.dx < minX) minX = p.dx;
          if (p.dx > maxX) maxX = p.dx;
          if (p.dy < minY) minY = p.dy;
          if (p.dy > maxY) maxY = p.dy;
        }
        return Rect.fromLTRB(
          minX,
          minY,
          maxX,
          maxY,
        ).inflate(ann.strokeWidth / 2);

      case CanvasTool.arrow:
        if (ann.startPoint == null || ann.endPoint == null) return Rect.zero;
        if (ann.controlPoint != null) {
          // Gene - Nov, 23, 2026: Tightly bound curved arrows by sampling the Bezier arc + flared arrowhead corners instead of the raw off-curve controlPoint.
          // Old:
          // final minX = math.min(
          //   ann.startPoint!.dx,
          //   math.min(ann.endPoint!.dx, ann.controlPoint!.dx),
          // );
          // final maxX = math.max(
          //   ann.startPoint!.dx,
          //   math.max(ann.endPoint!.dx, ann.controlPoint!.dx),
          // );
          // final minY = math.min(
          //   ann.startPoint!.dy,
          //   math.min(ann.endPoint!.dy, ann.controlPoint!.dy),
          // );
          // final maxY = math.max(
          //   ann.startPoint!.dy,
          //   math.max(ann.endPoint!.dy, ann.controlPoint!.dy),
          // );
          // return Rect.fromLTRB(
          //   minX,
          //   minY,
          //   maxX,
          //   maxY,
          // ).inflate(ann.strokeWidth / 2);
          final start = ann.startPoint!;
          final cp = ann.controlPoint!;
          final end = ann.endPoint!;
          const steps = 16;
          final pts = <Offset>[start];
          var arcLength = 0.0;
          var prev = start;
          for (int i = 1; i <= steps; i++) {
            final pt = _bezierPoint(start, cp, end, i / steps);
            arcLength += (pt - prev).distance;
            pts.add(pt);
            prev = pt;
          }
          final head = _curvedArrowHead(
            ann,
            arcLength > 0 ? arcLength : (end - start).distance,
          );
          void addHeadCorners(Offset tip, Offset tangent) {
            final tLen = tangent.distance;
            final dir = tLen > 0.05
                ? tangent / tLen
                : ((end - start).distance > 0.05
                      ? (end - start) / (end - start).distance
                      : const Offset(1, 0));
            final normal = Offset(-dir.dy, dir.dx);
            final base = tip - dir * head.length;
            pts.add(base + normal * head.halfWidth);
            pts.add(base - normal * head.halfWidth);
          }

          addHeadCorners(end, end - cp);
          if (ann.isDoubleArrow) {
            addHeadCorners(start, start - cp);
          }
          return _boundsThrough(pts, ann.strokeWidth / 2);
        }
        // The head flares wider than the shaft, so the span alone does not
        // bound the mark: take in the head's base corners as well, or the
        // selection guide sits inside the arrow point.
        return _boundsThrough(_arrowOutlinePoints(ann), ann.strokeWidth / 2);

      case CanvasTool.ruler:
        if (ann.startPoint == null || ann.endPoint == null) return Rect.zero;
        // The four cap ends, which is the true drawn extent: the caps run
        // perpendicular to the line, so the bounds have to be wide across the
        // ruler and only stroke-deep along it. Inflating uniformly by the
        // stroke weight, as the other two-point marks do, left the guide a
        // fraction of the size of the mark it was meant to enclose.
        final capHalf = rulerCapHalf(ann);
        final span = ann.endPoint! - ann.startPoint!;
        final length = span.distance;
        // Gene - Nov, 20, 2026: Lower minimum ruler length guard for zoomed-in precision.
        // Old: final normal = length < 1
        final normal = length < 0.05
            ? const Offset(0, 1)
            : Offset(-span.dy / length, span.dx / length);
        final corners = [
          ann.startPoint! - normal * capHalf,
          ann.startPoint! + normal * capHalf,
          ann.endPoint! - normal * capHalf,
          ann.endPoint! + normal * capHalf,
        ];
        var minX = corners.first.dx, maxX = corners.first.dx;
        var minY = corners.first.dy, maxY = corners.first.dy;
        for (final c in corners) {
          if (c.dx < minX) minX = c.dx;
          if (c.dx > maxX) maxX = c.dx;
          if (c.dy < minY) minY = c.dy;
          if (c.dy > maxY) maxY = c.dy;
        }
        return Rect.fromLTRB(
          minX,
          minY,
          maxX,
          maxY,
        ).inflate(ann.strokeWidth / 2);

      case CanvasTool.stepMarker:
        if (ann.startPoint == null) return Rect.zero;
        return Rect.fromCircle(
          center: ann.startPoint!,
          radius: _stepRadius(ann),
        );

      case CanvasTool.text:
        if (ann.startPoint == null || ann.text == null) return Rect.zero;
        // Gene - Nov, 20, 2026: Use crisp micro-text layout and proportional padding for zoomed-in text boxes.
        // Old:
        // final tp = _layoutText(ann);
        // return Rect.fromLTWH(
        //   ann.startPoint!.dx - _textPadX,
        //   ann.startPoint!.dy - _textPadY,
        //   tp.width + _textPadX * 2,
        //   tp.height + _textPadY * 2,
        // );
        final laidOut = _layoutCrispText(
          text: ann.text!,
          color: ann.color,
          fontSize: ann.fontSize,
          fontWeight: FontWeight.w600,
          height: 1.25,
        );
        final padX = _textPadXFor(ann);
        final padY = _textPadYFor(ann);
        return Rect.fromLTWH(
          ann.startPoint!.dx - padX,
          ann.startPoint!.dy - padY,
          laidOut.size.width + padX * 2,
          laidOut.size.height + padY * 2,
        );

      default:
        if (ann.startPoint != null && ann.endPoint != null) {
          // Gene - Nov, 23, 2026: Commented out unreachable duplicate arrow branch (handled in case CanvasTool.arrow above).
          // Old:
          // if (ann.tool == CanvasTool.arrow && ann.controlPoint != null) {
          //   final minX = math.min(
          //     ann.startPoint!.dx,
          //     math.min(ann.endPoint!.dx, ann.controlPoint!.dx),
          //   );
          //   final maxX = math.max(
          //     ann.startPoint!.dx,
          //     math.max(ann.endPoint!.dx, ann.controlPoint!.dx),
          //   );
          //   final minY = math.min(
          //     ann.startPoint!.dy,
          //     math.min(ann.endPoint!.dy, ann.controlPoint!.dy),
          //   );
          //   final maxY = math.max(
          //     ann.startPoint!.dy,
          //     math.max(ann.endPoint!.dy, ann.controlPoint!.dy),
          //   );
          //   return Rect.fromLTRB(
          //     minX,
          //     minY,
          //     maxX,
          //     maxY,
          //   ).inflate(ann.strokeWidth / 2);
          // }
          final span = Rect.fromPoints(ann.startPoint!, ann.endPoint!);
          // A line, arrow or ruler *is* its stroke, so its bounds have to
          // include the width — otherwise a thick one spills well outside its
          // own selection box, and the handles sit buried inside the mark
          // instead of on its edge. Pen, highlighter and curved arrows already
          // inflate in their own branches; a shape or a blur is bounded by its
          // rect rather than by its outline, so those keep the raw span.
          return _strokeBoundedTools.contains(ann.tool)
              ? span.inflate(ann.strokeWidth / 2)
              : span;
        }
        return Rect.zero;
    }
  }

  /// Axis-aligned bounds of [points], inflated by [padding].
  static Rect _boundsThrough(List<Offset> points, double padding) {
    if (points.isEmpty) return Rect.zero;
    var minX = points.first.dx, maxX = points.first.dx;
    var minY = points.first.dy, maxY = points.first.dy;
    for (final p in points) {
      if (p.dx < minX) minX = p.dx;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dy > maxY) maxY = p.dy;
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY).inflate(padding);
  }

  /// The extreme points of a straight arrow: both ends, plus the corners where
  /// each head flares widest.
  static List<Offset> _arrowOutlinePoints(Annotation ann) {
    final start = ann.startPoint!;
    final end = ann.endPoint!;
    final span = end - start;
    final length = span.distance;
    if (length < 0.5) return [start, end];

    final head = arrowHead(ann);
    final direction = span / length;
    final normal = Offset(-direction.dy, direction.dx);

    List<Offset> cornersAt(Offset tip, double sign) {
      final base = tip - direction * (head.length * sign);
      return [base + normal * head.halfWidth, base - normal * head.halfWidth];
    }

    return [
      start,
      end,
      ...cornersAt(end, 1),
      if (ann.isDoubleArrow) ...cornersAt(start, -1),
    ];
  }

  /// Bounds of the selection frame drawn around [ann].
  // Gene - Nov, 20, 2026: Scale selection inset and hit-testing tolerance inversely with viewScale so handles & hit-boxes stay constant screen size.
  // Old:
  // static Rect selectionRect(Annotation ann) {
  //   final raw = boundingRect(ann);
  //   if (raw == Rect.zero) return Rect.zero;
  //   return raw.inflate(selectionInset);
  // }
  static Rect selectionRect(Annotation ann, {double viewScale = 1.0}) {
    final raw = boundingRect(ann);
    if (raw == Rect.zero) return Rect.zero;
    return raw.inflate(selectionInset / _safeScale(viewScale));
  }

  /// Maps a canvas point into the annotation's own un-rotated coordinate space
  /// so hit testing stays accurate after the item has been rotated.
  static Offset toLocalSpace(Annotation ann, Offset point) {
    if (ann.rotation == 0.0) return point;
    final center = boundingRect(ann).center;
    final cos = math.cos(-ann.rotation);
    final sin = math.sin(-ann.rotation);
    final dx = point.dx - center.dx;
    final dy = point.dy - center.dy;
    return Offset(
      center.dx + dx * cos - dy * sin,
      center.dy + dx * sin + dy * cos,
    );
  }

  /// Maps a point from the annotation's local space back to canvas space.
  static Offset toCanvasSpace(Annotation ann, Offset point) {
    if (ann.rotation == 0.0) return point;
    final center = boundingRect(ann).center;
    final cos = math.cos(ann.rotation);
    final sin = math.sin(ann.rotation);
    final dx = point.dx - center.dx;
    final dy = point.dy - center.dy;
    return Offset(
      center.dx + dx * cos - dy * sin,
      center.dy + dx * sin + dy * cos,
    );
  }

  /// Loose fallback used when nothing was hit precisely: the whole (rotated)
  /// bounding box counts. Lets users grab a large hollow rectangle by clicking
  /// inside it when there is nothing underneath to select instead.
  // Gene - Nov, 20, 2026: Divide hitPadding by viewScale so hit-testing matches constant screen pixels at every zoom level.
  static bool hitTestBounds(
    Annotation ann,
    Offset canvasPoint, {
    double viewScale = 1.0,
  }) {
    final rect = boundingRect(ann);
    if (rect == Rect.zero) return false;
    final pad = hitPadding / _safeScale(viewScale);
    return rect.inflate(pad).contains(toLocalSpace(ann, canvasPoint));
  }

  static bool hitTest(
    Annotation ann,
    Offset canvasPoint, {
    double viewScale = 1.0,
  }) {
    final point = toLocalSpace(ann, canvasPoint);
    final s = _safeScale(viewScale);
    final pad = hitPadding / s;

    switch (ann.tool) {
      case CanvasTool.shape:
        if (ann.startPoint == null || ann.endPoint == null) return false;
        // A filled shape is grabbable anywhere its outline encloses; a hollow
        // one only near the outline itself, so clicks pass through the middle
        // to whatever sits underneath (Figma/Snagit behaviour).
        if (ann.fill) {
          return shapePath(ann).contains(point) ||
              _isNearShapeOutline(ann, point, viewScale: s);
        }
        return _isNearShapeOutline(ann, point, viewScale: s);

      case CanvasTool.crop:
      case CanvasTool.blur:
      // A patch is opaque pixels, so the whole rect is grabbable — unlike a
      // hollow shape, there is nothing to click "through".
      case CanvasTool.imagePatch:
        if (ann.startPoint == null || ann.endPoint == null) return false;
        return Rect.fromPoints(
          ann.startPoint!,
          ann.endPoint!,
        ).inflate(pad).contains(point);

      case CanvasTool.arrow:
        if (ann.startPoint == null || ann.endPoint == null) return false;
        if (ann.controlPoint != null) {
          final tolerance = ann.strokeWidth / 2 + pad;
          Offset prev = ann.startPoint!;
          const steps = 16;
          for (int i = 1; i <= steps; i++) {
            final t = i / steps;
            final curr = _bezierPoint(
              ann.startPoint!,
              ann.controlPoint!,
              ann.endPoint!,
              t,
            );
            if (_distanceToSegment(point, prev, curr) <= tolerance) {
              return true;
            }
            prev = curr;
          }
          return false;
        }
        return _distanceToSegment(point, ann.startPoint!, ann.endPoint!) <=
            (ann.strokeWidth / 2 + pad);

      case CanvasTool.line:
      case CanvasTool.ruler:
        if (ann.startPoint == null || ann.endPoint == null) return false;
        return _distanceToSegment(point, ann.startPoint!, ann.endPoint!) <=
            (ann.strokeWidth / 2 + pad);

      case CanvasTool.pen:
      case CanvasTool.highlight:
        if (ann.points.isEmpty) return false;
        final tolerance = ann.strokeWidth / 2 + pad;
        if (ann.points.length == 1) {
          return (point - ann.points.first).distance <= tolerance;
        }
        for (int i = 0; i < ann.points.length - 1; i++) {
          if (_distanceToSegment(point, ann.points[i], ann.points[i + 1]) <=
              tolerance) {
            return true;
          }
        }
        return false;

      case CanvasTool.stepMarker:
        if (ann.startPoint == null) return false;
        return (point - ann.startPoint!).distance <= (_stepRadius(ann) + pad);

      case CanvasTool.text:
        final rect = boundingRect(ann);
        return rect != Rect.zero && rect.inflate(pad).contains(point);

      default:
        final rect = boundingRect(ann);
        return rect != Rect.zero && rect.inflate(pad).contains(point);
    }
  }

  /// True when [point] lies within grabbing distance of a shape's outline.
  ///
  /// Walks the path metrics and measures against the flattened segments, so it
  /// works for every shape kind including stars and speech bubbles.
  static bool _isNearShapeOutline(
    Annotation ann,
    Offset point, {
    double viewScale = 1.0,
  }) {
    final path = shapePath(ann);
    if (path.getBounds().isEmpty) return false;

    final pad = hitPadding / _safeScale(viewScale);
    final tolerance = ann.strokeWidth / 2 + pad;
    // Cheap rejection before the (more expensive) per-segment walk.
    if (!path.getBounds().inflate(tolerance).contains(point)) return false;

    for (final metric in path.computeMetrics()) {
      if (metric.length == 0) continue;
      // Sample densely enough that curves stay within tolerance.
      final steps = math.max(
        16,
        (metric.length / math.max(0.2, tolerance / 2)).ceil(),
      );
      Offset? previous;
      for (int i = 0; i <= steps; i++) {
        final tangent = metric.getTangentForOffset(metric.length * i / steps);
        if (tangent == null) continue;
        final current = tangent.position;
        if (previous != null &&
            _distanceToSegment(point, previous, current) <= tolerance) {
          return true;
        }
        previous = current;
      }
    }
    return false;
  }

  static double _distanceToSegment(Offset p, Offset v, Offset w) {
    final l2 = (v - w).distanceSquared;
    if (l2 == 0) return (p - v).distance;
    var t =
        ((p.dx - v.dx) * (w.dx - v.dx) + (p.dy - v.dy) * (w.dy - v.dy)) / l2;
    t = t.clamp(0.0, 1.0);
    final projection = Offset(
      v.dx + t * (w.dx - v.dx),
      v.dy + t * (w.dy - v.dy),
    );
    return (p - projection).distance;
  }

  static Offset _bezierPoint(Offset p0, Offset p1, Offset p2, double t) {
    final u = 1.0 - t;
    return Offset(
      u * u * p0.dx + 2 * u * t * p1.dx + t * t * p2.dx,
      u * u * p0.dy + 2 * u * t * p1.dy + t * t * p2.dy,
    );
  }

  static double _stepRadius(Annotation ann) =>
      ann.fontSize > 0 ? ann.fontSize : 16.0;

  static const double _textPadX = 8.0;
  static const double _textPadY = 5.0;

  // Gene - Nov, 20, 2026: Scale text box padding & lay out small zoomed-in fonts at 16pt before canvas.scale so glyphs stay crisp.
  static double _textPadXFor(Annotation ann) => ann.fontSize >= 16.0
      ? _textPadX
      : math.min(_textPadX, ann.fontSize * 0.44);
  static double _textPadYFor(Annotation ann) => ann.fontSize >= 16.0
      ? _textPadY
      : math.min(_textPadY, ann.fontSize * 0.28);

  static ({TextPainter tp, double scale, Size size}) _layoutCrispText({
    required String text,
    required Color color,
    required double fontSize,
    required FontWeight fontWeight,
    double? height,
    bool hasShadows = false,
  }) {
    final safeFont = fontSize.clamp(0.5, 240.0);
    if (safeFont >= 16.0) {
      final tp = _cachedTextPainter(
        text: text,
        color: color,
        fontSize: safeFont,
        fontWeight: fontWeight,
        height: height,
        hasShadows: hasShadows,
      );
      return (tp: tp, scale: 1.0, size: Size(tp.width, tp.height));
    }
    const baseSize = 16.0;
    final scale = safeFont / baseSize;
    final tp = _cachedTextPainter(
      text: text,
      color: color,
      fontSize: baseSize,
      fontWeight: fontWeight,
      height: height,
      hasShadows: hasShadows,
    );
    return (
      tp: tp,
      scale: scale,
      size: Size(tp.width * scale, tp.height * scale),
    );
  }

  static void _paintCrispText(
    Canvas canvas,
    TextPainter tp,
    Offset origin,
    double scale,
  ) {
    if ((scale - 1.0).abs() <= 1e-4) {
      tp.paint(canvas, origin);
      return;
    }
    canvas.save();
    canvas.translate(origin.dx, origin.dy);
    canvas.scale(scale);
    tp.paint(canvas, Offset.zero);
    canvas.restore();
  }

  // Gene - Nov, 20, 2026: Bounded LRU TextPainter cache (128 entries) to eliminate repeated paragraph shaping on paint/hit-test frames.
  static const int _maxTextCacheEntries = 128;
  static final LinkedHashMap<Object, TextPainter> _textPainterCache =
      LinkedHashMap<Object, TextPainter>();
  static const List<Shadow> _defaultTextShadows = [
    Shadow(color: Color(0xB3000000), offset: Offset(0, 1), blurRadius: 4),
  ];

  static TextPainter _cachedTextPainter({
    required String text,
    required Color color,
    required double fontSize,
    required FontWeight fontWeight,
    double? height,
    bool hasShadows = false,
    TextAlign textAlign = TextAlign.left,
  }) {
    final key = (
      text,
      color.toARGB32(),
      fontSize,
      // Gene - Nov, 20, 2026: Use FontWeight.value (non-deprecated) instead of FontWeight.index for cache key.
      // Old: fontWeight.index,
      fontWeight.value,
      height ?? -1.0,
      hasShadows,
      textAlign.index,
    );
    final existing = _textPainterCache.remove(key);
    if (existing != null) {
      _textPainterCache[key] = existing;
      return existing;
    }

    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: fontWeight,
          height: height,
          shadows: hasShadows ? _defaultTextShadows : null,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: textAlign,
    )..layout();

    _textPainterCache[key] = tp;
    if (_textPainterCache.length > _maxTextCacheEntries) {
      final oldestKey = _textPainterCache.keys.first;
      final evicted = _textPainterCache.remove(oldestKey);
      evicted?.dispose();
    }
    return tp;
  }

  // Old implementation:
  // static TextPainter _layoutText(Annotation ann) {
  //   final tp = TextPainter(
  //     text: TextSpan(
  //       text: ann.text ?? '',
  //       style: TextStyle(
  //         color: ann.color,
  //         fontSize: ann.fontSize,
  //         fontWeight: FontWeight.w600,
  //         height: 1.25,
  //       ),
  //     ),
  //     textDirection: TextDirection.ltr,
  //     textAlign: TextAlign.left,
  //   );
  //   tp.layout();
  //   return tp;
  // }
  // Gene - Nov, 20, 2026: Replaced _layoutText with _layoutCrispText (keeps old code commented per policy).
  // static TextPainter _layoutText(Annotation ann) {
  //   return _cachedTextPainter(
  //     text: ann.text ?? '',
  //     color: ann.color,
  //     fontSize: ann.fontSize,
  //     fontWeight: FontWeight.w600,
  //     height: 1.25,
  //     textAlign: TextAlign.left,
  //   );
  // }

  // ---------------------------------------------------------------------------
  // Painting
  // ---------------------------------------------------------------------------

  /// Draws every annotation in order. [baseImage] and [imageRect] are only
  /// needed for blur/pixelate regions, which sample the underlying pixels; the
  /// live canvas passes null and layers a real BackdropFilter instead.
  ///
  /// [pixelScale] is how many native image pixels one canvas unit covers. It
  /// affects no geometry — only the ruler's reported measurement, which has to
  /// be in the image's own pixels rather than in display pixels that change
  /// with the window size.
  /// [patchImages] supplies the decoded bitmap for each [CanvasTool.imagePatch]
  /// annotation, keyed by annotation id. Painting is synchronous and decoding
  /// is not, so the caller decodes ahead: the editor keeps a cache alongside
  /// its annotation list, and the export path decodes before it starts
  /// recording. A patch with no entry is skipped rather than drawn empty.
  static void paintAll(
    Canvas canvas,
    List<Annotation> annotations, {
    ui.Image? baseImage,
    Rect? imageRect,
    double pixelScale = 1.0,
    Map<String, ui.Image>? patchImages,
  }) {
    for (final ann in annotations) {
      paint(
        canvas,
        ann,
        baseImage: baseImage,
        imageRect: imageRect,
        pixelScale: pixelScale,
        patchImages: patchImages,
      );
    }
  }

  static void paint(
    Canvas canvas,
    Annotation ann, {
    ui.Image? baseImage,
    Rect? imageRect,
    double pixelScale = 1.0,
    Map<String, ui.Image>? patchImages,
  }) {
    final bounds = boundingRect(ann);
    final rotated = ann.rotation != 0.0 && bounds != Rect.zero;

    if (rotated) {
      canvas.save();
      final center = bounds.center;
      canvas.translate(center.dx, center.dy);
      canvas.rotate(ann.rotation);
      canvas.translate(-center.dx, -center.dy);
    }

    switch (ann.tool) {
      case CanvasTool.pen:
        _drawFreehand(canvas, ann, isHighlighter: false);
      case CanvasTool.highlight:
        _drawFreehand(canvas, ann, isHighlighter: true);
      case CanvasTool.arrow:
        _drawArrow(canvas, ann);
      case CanvasTool.line:
        _drawLine(canvas, ann);
      case CanvasTool.shape:
        _drawShape(canvas, ann);
      case CanvasTool.ruler:
        _drawRuler(canvas, ann, pixelScale);
      case CanvasTool.blur:
        _drawBlur(canvas, ann, baseImage: baseImage, imageRect: imageRect);
      case CanvasTool.stepMarker:
        _drawStepMarker(canvas, ann);
      case CanvasTool.text:
        _drawText(canvas, ann);
      case CanvasTool.imagePatch:
        _drawImagePatch(canvas, ann, patchImages?[ann.id]);
      default:
    }

    if (rotated) canvas.restore();
  }

  /// Draws a cut-out region into the rect it has been moved to.
  ///
  /// [image] is null until the decode lands, and on the frame a patch is first
  /// created. Drawing nothing is right for both: the alternative is a black
  /// rectangle where the pixels belong.
  static void _drawImagePatch(Canvas canvas, Annotation ann, ui.Image? image) {
    if (image == null) return;
    if (ann.startPoint == null || ann.endPoint == null) return;
    final dst = Rect.fromPoints(ann.startPoint!, ann.endPoint!);
    if (dst.isEmpty) return;

    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      dst,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..color = const Color(0xFFFFFFFF).withValues(alpha: ann.opacity),
    );
  }

  static Color _applyOpacity(Color color, double opacity) {
    return color.withValues(alpha: (color.a * opacity).clamp(0.0, 1.0));
  }

  static Paint _strokePaint(Annotation ann) {
    return Paint()
      ..color = _applyOpacity(ann.color, ann.opacity)
      ..strokeWidth = ann.strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
  }

  /// Effective fill for a shape: the explicit fill colour when set, otherwise a
  /// translucent tint of the stroke colour.
  static Color _effectiveFill(Annotation ann) {
    // The fill carries its own transparency in its colour's alpha, and that is
    // the only opacity it answers to. `ann.opacity` — the panel's OPACITY
    // slider — is the outline's: it used to multiply into the fill as well,
    // so fading the border also faded the centre and the two could not be set
    // apart. A null fill colour means "match the outline", at full strength.
    return ann.fillColor ?? ann.color.withValues(alpha: 1.0);
  }

  static void _withShadow(Canvas canvas, Annotation ann, VoidCallback draw) {
    if (!ann.hasShadow) {
      draw();
      return;
    }
    // Gene - Nov, 20, 2026: Scale drop shadow blur/offset down on thin zoomed-in strokes.
    // Old:
    // final layerBounds = boundingRect(ann).inflate(ann.strokeWidth + 12);
    // ... ImageFilter.blur(sigmaX: 2.5, sigmaY: 2.5) ...
    // canvas.translate(0, 1.5);
    final shadowScale = (ann.strokeWidth / 4.0).clamp(0.05, 1.0);
    final layerBounds = boundingRect(
      ann,
    ).inflate(ann.strokeWidth + 12.0 * shadowScale);
    // Re-draw the shape through a black-tinted blurred layer to produce a
    // cheap drop shadow that keeps markup readable over busy screenshots.
    canvas.saveLayer(
      layerBounds,
      Paint()
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: 2.5 * shadowScale,
          sigmaY: 2.5 * shadowScale,
        )
        ..colorFilter = ColorFilter.mode(
          Colors.black.withValues(alpha: 0.42 * ann.opacity),
          BlendMode.srcIn,
        ),
    );
    canvas.translate(0, 1.5 * shadowScale);
    draw();
    canvas.restore();
    draw();
  }

  // --- Freehand -------------------------------------------------------------

  /// Builds a smoothed path through [points] using quadratic midpoint
  /// interpolation, removing the polyline faceting of raw segment drawing.
  static Path _smoothPath(List<Offset> points) {
    final path = Path();
    if (points.isEmpty) return path;
    if (points.length == 1) {
      path.moveTo(points.first.dx, points.first.dy);
      path.lineTo(points.first.dx + 0.01, points.first.dy);
      return path;
    }

    path.moveTo(points.first.dx, points.first.dy);
    if (points.length == 2) {
      path.lineTo(points[1].dx, points[1].dy);
      return path;
    }

    for (int i = 1; i < points.length - 1; i++) {
      final mid = Offset(
        (points[i].dx + points[i + 1].dx) / 2,
        (points[i].dy + points[i + 1].dy) / 2,
      );
      path.quadraticBezierTo(points[i].dx, points[i].dy, mid.dx, mid.dy);
    }
    path.lineTo(points.last.dx, points.last.dy);
    return path;
  }

  static void _drawFreehand(
    Canvas canvas,
    Annotation ann, {
    required bool isHighlighter,
  }) {
    if (ann.points.isEmpty) return;
    final path = _smoothPath(ann.points);

    if (isHighlighter) {
      // Flatten the stroke in its own layer and apply the translucency on
      // restore. Drawing a semi-transparent stroke directly would darken every
      // place the stroke crosses itself, which real highlighters do not do.
      final alpha = (ann.color.a * ann.opacity * 0.45).clamp(0.0, 1.0);
      canvas.saveLayer(
        boundingRect(ann).inflate(ann.strokeWidth),
        Paint()..color = Colors.black.withValues(alpha: alpha),
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = ann.color.withValues(alpha: 1.0)
          ..strokeWidth = ann.strokeWidth
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.square
          ..strokeJoin = StrokeJoin.round
          ..isAntiAlias = true,
      );
      canvas.restore();
      return;
    }

    _withShadow(canvas, ann, () => canvas.drawPath(path, _strokePaint(ann)));
  }

  // --- Lines & arrows -------------------------------------------------------

  static void _drawDashedPath(
    Canvas canvas,
    Offset p1,
    Offset p2,
    Paint paint,
  ) {
    final distance = (p2 - p1).distance;
    if (distance == 0) return;
    final direction = (p2 - p1) / distance;
    // Gene - Nov, 20, 2026: Lower dash floors so thin zoomed dashed lines stay proportional.
    // Old:
    // final dashWidth = math.max(6.0, paint.strokeWidth * 2.5);
    // final dashSpace = math.max(4.0, paint.strokeWidth * 1.8);
    final dashWidth = math.max(0.2, paint.strokeWidth * 2.5);
    final dashSpace = math.max(0.15, paint.strokeWidth * 1.8);

    double travelled = 0.0;
    while (travelled < distance) {
      final start = p1 + direction * travelled;
      final end = p1 + direction * math.min(travelled + dashWidth, distance);
      canvas.drawLine(start, end, paint);
      travelled += dashWidth + dashSpace;
    }
  }

  static void _drawLine(Canvas canvas, Annotation ann) {
    if (ann.startPoint == null || ann.endPoint == null) return;
    final paint = _strokePaint(ann);
    _withShadow(canvas, ann, () {
      if (ann.lineStyle == LineStyle.dashed) {
        _drawDashedPath(canvas, ann.startPoint!, ann.endPoint!, paint);
      } else {
        canvas.drawLine(ann.startPoint!, ann.endPoint!, paint);
      }
    });
  }

  static void _drawArrow(Canvas canvas, Annotation ann) {
    final start = ann.startPoint;
    final end = ann.endPoint;
    if (start == null || end == null) return;
    // Gene - Nov, 20, 2026: Lower minimum arrow span and curved head floor for zoomed-in precision.
    // Old: if ((end - start).distance < 0.5) return;
    if ((end - start).distance < 0.05) return;

    final paint = _strokePaint(ann);
    // Gene - Nov, 23, 2026: Commented out unused strokeW after delegating curved arrowhead sizing to _curvedArrowHead.
    // Old: final strokeW = ann.strokeWidth;
    final cp = ann.controlPoint;

    final fillPaint = Paint()
      ..color = paint.color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    if (cp != null) {
      // Curved Bezier arrow
      final endTangent = (end - cp);
      final endAngle = endTangent.distance > 0.05
          ? math.atan2(endTangent.dy, endTangent.dx)
          : math.atan2(end.dy - start.dy, end.dx - start.dx);

      final startTangent = (start - cp);
      final startAngle = startTangent.distance > 0.05
          ? math.atan2(startTangent.dy, startTangent.dx)
          : math.atan2(start.dy - end.dy, start.dx - end.dx);

      // Old:
      // final headLength = math.max(0.5, strokeW * 4.0);
      // final headHalfWidth = headLength * 0.45;
      // Path headPath(Offset tip, double angle) { ... }
      // final shaftPath = Path()
      //   ..moveTo(start.dx, start.dy)
      //   ..quadraticBezierTo(cp.dx, cp.dy, end.dx, end.dy);
      // _withShadow(canvas, ann, () {
      //   if (ann.lineStyle == LineStyle.dashed) {
      //     _drawDashedPath2(canvas, shaftPath, paint);
      //   } else {
      //     canvas.drawPath(shaftPath, paint);
      //   }
      //   canvas.drawPath(headPath(end, endAngle), fillPaint);
      //   if (ann.isDoubleArrow) {
      //     canvas.drawPath(headPath(start, startAngle), fillPaint);
      //   }
      // });
      // Gene - Nov, 23, 2026: Pull back curved Bezier shaft from filled arrowheads so thick/translucent tips never overlap or poke through.
      final shaftPath = Path()
        ..moveTo(start.dx, start.dy)
        ..quadraticBezierTo(cp.dx, cp.dy, end.dx, end.dy);
      final metrics = shaftPath.computeMetrics().toList();
      final totalLen = metrics.fold<double>(0.0, (sum, m) => sum + m.length);
      final head = _curvedArrowHead(
        ann,
        totalLen > 0 ? totalLen : (end - start).distance,
      );
      final headLength = head.length;
      final headHalfWidth = head.halfWidth;

      Path headPath(Offset tip, double angle) {
        final baseCenter = Offset(
          tip.dx - headLength * math.cos(angle),
          tip.dy - headLength * math.sin(angle),
        );
        final normal = Offset(-math.sin(angle), math.cos(angle));
        return Path()
          ..moveTo(tip.dx, tip.dy)
          ..lineTo(
            baseCenter.dx + normal.dx * headHalfWidth,
            baseCenter.dy + normal.dy * headHalfWidth,
          )
          ..lineTo(
            baseCenter.dx - normal.dx * headHalfWidth,
            baseCenter.dy - normal.dy * headHalfWidth,
          )
          ..close();
      }

      final pullback = headLength * 0.75;
      final Path? trimmedShaft;
      if (metrics.length == 1 && totalLen > 0) {
        final trimStart = ann.isDoubleArrow ? pullback : 0.0;
        final trimEnd = totalLen - pullback;
        trimmedShaft = trimEnd > trimStart
            ? metrics.first.extractPath(trimStart, trimEnd)
            : null;
      } else {
        trimmedShaft = shaftPath;
      }

      _withShadow(canvas, ann, () {
        if (trimmedShaft != null) {
          if (ann.lineStyle == LineStyle.dashed) {
            _drawDashedPath2(canvas, trimmedShaft, paint);
          } else {
            canvas.drawPath(trimmedShaft, paint);
          }
        }
        canvas.drawPath(headPath(end, endAngle), fillPaint);
        if (ann.isDoubleArrow) {
          canvas.drawPath(headPath(start, startAngle), fillPaint);
        }
      });
      return;
    }

    final angle = math.atan2(end.dy - start.dy, end.dx - start.dx);

    // Head scales with stroke weight but never overwhelms a short arrow. Both
    // dimensions come from one helper that `boundingRect` shares.
    final head = arrowHead(ann);
    final headLength = head.length;
    final headHalfWidth = head.halfWidth;

    Offset shorten(Offset from, double by, double dir) => Offset(
      from.dx - dir * by * math.cos(angle),
      from.dy - dir * by * math.sin(angle),
    );

    // Pull the shaft back so it does not poke through the filled head.
    final shaftEnd = shorten(end, headLength * 0.75, 1);
    final shaftStart = ann.isDoubleArrow
        ? shorten(start, headLength * 0.75, -1)
        : start;

    Path headPath(Offset tip, double dir) {
      final baseCenter = Offset(
        tip.dx - dir * headLength * math.cos(angle),
        tip.dy - dir * headLength * math.sin(angle),
      );
      final normal = Offset(-math.sin(angle), math.cos(angle));
      return Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo(
          baseCenter.dx + normal.dx * headHalfWidth,
          baseCenter.dy + normal.dy * headHalfWidth,
        )
        ..lineTo(
          baseCenter.dx - normal.dx * headHalfWidth,
          baseCenter.dy - normal.dy * headHalfWidth,
        )
        ..close();
    }

    _withShadow(canvas, ann, () {
      if (ann.lineStyle == LineStyle.dashed) {
        _drawDashedPath(canvas, shaftStart, shaftEnd, paint);
      } else {
        canvas.drawLine(shaftStart, shaftEnd, paint);
      }
      canvas.drawPath(headPath(end, 1), fillPaint);
      if (ann.isDoubleArrow) {
        canvas.drawPath(headPath(start, -1), fillPaint);
      }
    });
  }

  // --- Shapes ---------------------------------------------------------------

  /// Outline of a [CanvasTool.shape] annotation, in canvas coordinates.
  ///
  /// Every kind is inscribed in the drag rectangle so all shapes resize,
  /// rotate and hit-test through the same bounding box.
  static Path shapePath(Annotation ann) {
    final start = ann.startPoint;
    final end = ann.endPoint;
    if (start == null || end == null) return Path();
    final rect = Rect.fromPoints(start, end);
    if (rect.width <= 0 || rect.height <= 0) return Path();

    switch (ann.shapeKind) {
      case ShapeKind.rectangle:
        final maxRadius = math.min(rect.width, rect.height) / 2;
        return Path()..addRRect(
          RRect.fromRectAndRadius(
            rect,
            Radius.circular(
              ann.borderRadius.clamp(0.0, math.max(0.0, maxRadius)),
            ),
          ),
        );

      case ShapeKind.ellipse:
        return Path()..addOval(rect);

      case ShapeKind.triangle:
        return Path()
          ..moveTo(rect.center.dx, rect.top)
          ..lineTo(rect.right, rect.bottom)
          ..lineTo(rect.left, rect.bottom)
          ..close();

      case ShapeKind.diamond:
        return Path()
          ..moveTo(rect.center.dx, rect.top)
          ..lineTo(rect.right, rect.center.dy)
          ..lineTo(rect.center.dx, rect.bottom)
          ..lineTo(rect.left, rect.center.dy)
          ..close();

      case ShapeKind.pentagon:
        return _regularPolygon(rect, 5);

      case ShapeKind.hexagon:
        return _regularPolygon(rect, 6);

      case ShapeKind.star:
        return _star(rect, points: 5, innerRatio: 0.42);

      case ShapeKind.speechBubble:
        return _speechBubble(rect, ann.borderRadius);
    }
  }

  /// [sides]-sided polygon inscribed in [rect], first vertex pointing up.
  static Path _regularPolygon(Rect rect, int sides) {
    final path = Path();
    final cx = rect.center.dx;
    final cy = rect.center.dy;
    final rx = rect.width / 2;
    final ry = rect.height / 2;
    for (int i = 0; i < sides; i++) {
      final angle = -math.pi / 2 + i * 2 * math.pi / sides;
      final x = cx + rx * math.cos(angle);
      final y = cy + ry * math.sin(angle);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    return path..close();
  }

  static Path _star(
    Rect rect, {
    required int points,
    required double innerRatio,
  }) {
    final path = Path();
    final cx = rect.center.dx;
    final cy = rect.center.dy;
    final rx = rect.width / 2;
    final ry = rect.height / 2;
    for (int i = 0; i < points * 2; i++) {
      final isOuter = i.isEven;
      final scale = isOuter ? 1.0 : innerRatio;
      final angle = -math.pi / 2 + i * math.pi / points;
      final x = cx + rx * scale * math.cos(angle);
      final y = cy + ry * scale * math.sin(angle);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    return path..close();
  }

  /// Rounded box with a tail on the lower-left, sized so the tail always fits.
  static Path _speechBubble(Rect rect, double borderRadius) {
    final tailHeight = math.min(rect.height * 0.22, 22.0);
    final body = Rect.fromLTRB(
      rect.left,
      rect.top,
      rect.right,
      rect.bottom - tailHeight,
    );
    if (body.height <= 0) return Path()..addRect(rect);

    final radius = borderRadius.clamp(
      0.0,
      math.min(body.width, body.height) / 2,
    );
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(body, Radius.circular(radius)));

    final tailLeft = body.left + body.width * 0.22;
    final tailRight = tailLeft + math.min(body.width * 0.18, 26.0);
    path
      ..moveTo(tailLeft, body.bottom - 1)
      ..lineTo(tailLeft, rect.bottom)
      ..lineTo(tailRight, body.bottom - 1)
      ..close();
    return path;
  }

  static void _drawShape(Canvas canvas, Annotation ann) {
    final path = shapePath(ann);
    if (path.getBounds().isEmpty) return;

    _withShadow(canvas, ann, () {
      if (ann.fill) {
        canvas.drawPath(
          path,
          Paint()
            ..color = _effectiveFill(ann)
            ..isAntiAlias = true,
        );
      }
      final stroke = _strokePaint(ann);
      if (ann.lineStyle == LineStyle.dashed) {
        _drawDashedPath2(canvas, path, stroke);
      } else {
        canvas.drawPath(path, stroke);
      }
    });
  }

  /// Dashes an arbitrary path by walking its metrics.
  static void _drawDashedPath2(Canvas canvas, Path source, Paint paint) {
    // Gene - Nov, 20, 2026: Lower dash floors so thin zoomed dashed lines stay proportional.
    // Old:
    // final dashWidth = math.max(6.0, paint.strokeWidth * 2.5);
    // final dashSpace = math.max(4.0, paint.strokeWidth * 1.8);
    final dashWidth = math.max(0.2, paint.strokeWidth * 2.5);
    final dashSpace = math.max(0.15, paint.strokeWidth * 1.8);
    for (final metric in source.computeMetrics()) {
      double distance = 0.0;
      while (distance < metric.length) {
        final next = math.min(distance + dashWidth, metric.length);
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance = next + dashSpace;
      }
    }
  }

  // --- Ruler ----------------------------------------------------------------

  /// Text shown in the ruler's badge.
  ///
  /// The annotation's geometry is in canvas units, but what the user is
  /// measuring is the screenshot, so the reported number is scaled into the
  /// image's native pixels. [pixelScale] is image pixels per canvas unit; 1.0
  /// means the annotation is already in image pixels.
  static String rulerLabel(Annotation ann, double pixelScale) {
    final start = ann.startPoint;
    final end = ann.endPoint;
    if (start == null || end == null) return '';
    return '${((end - start).distance * pixelScale).round()} px';
  }

  /// Measurement tool: a capped baseline with tick marks and a pixel-distance
  /// badge, matching Shottr's ruler.
  static void _drawRuler(Canvas canvas, Annotation ann, double pixelScale) {
    final start = ann.startPoint;
    final end = ann.endPoint;
    if (start == null || end == null) return;

    final paint = _strokePaint(ann);
    final length = (end - start).distance;
    // Gene - Nov, 20, 2026: Scale ruler min span, tick intervals (image pixels), tick stroke, and badge size proportionally.
    // Old: if (length < 1) return;
    if (length < 0.05) return;

    final angle = math.atan2(end.dy - start.dy, end.dx - start.dx);
    final normal = Offset(-math.sin(angle), math.cos(angle));
    final capHalf = rulerCapHalf(ann);

    canvas.drawLine(start, end, paint);
    // End caps
    canvas.drawLine(start - normal * capHalf, start + normal * capHalf, paint);
    canvas.drawLine(end - normal * capHalf, end + normal * capHalf, paint);

    // Ruler ticks every 10 image px, taller every 50 image px.
    final direction = (end - start) / length;
    final tickPaint = Paint()
      ..color = paint.color.withValues(alpha: paint.color.a * 0.85)
      ..strokeWidth = math.max(0.1, ann.strokeWidth * 0.6)
      ..strokeCap = StrokeCap.butt;
    final tickStep = 10.0 / math.max(1.0, pixelScale);
    int tickIdx = 1;
    while (tickIdx * tickStep < length && tickIdx < 2000) {
      final isMajor = tickIdx % 5 == 0;
      final tickLen = isMajor ? capHalf * 0.75 : capHalf * 0.4;
      final p = start + direction * (tickIdx * tickStep);
      canvas.drawLine(p, p + normal * tickLen, tickPaint);
      tickIdx++;
    }

    final badgeScale = math.min(1.0, ann.strokeWidth / 2.0).clamp(0.04, 1.0);
    _drawBadge(
      canvas,
      center:
          Offset((start.dx + end.dx) / 2, (start.dy + end.dy) / 2) -
          normal * (capHalf + 12.0 * badgeScale),
      text: rulerLabel(ann, pixelScale),
      background: _applyOpacity(ann.color, ann.opacity),
      scale: badgeScale,
    );
  }

  // Gene - Nov, 23, 2026: Allow badge textColor & optional borderColor so HUD pills stay monochrome contrast across themes.
  // Old:
  // static void _drawBadge(
  //   Canvas canvas, {
  //   required Offset center,
  //   required String text,
  //   required Color background,
  //   double scale = 1.0,
  // }) {
  static void _drawBadge(
    Canvas canvas, {
    required Offset center,
    required String text,
    required Color background,
    Color textColor = Colors.white,
    Color? borderColor,
    double scale = 1.0,
  }) {
    final tp = _cachedTextPainter(
      text: text,
      color: textColor,
      fontSize: 11,
      fontWeight: FontWeight.bold,
    );

    final s = _safeScale(scale);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    if ((s - 1.0).abs() > 1e-4) canvas.scale(s);

    final rect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset.zero,
        width: tp.width + 14,
        height: tp.height + 7,
      ),
      const Radius.circular(9),
    );
    canvas.drawRRect(
      rect,
      Paint()
        ..color = background
        ..isAntiAlias = true,
    );
    if (borderColor != null) {
      canvas.drawRRect(
        rect,
        Paint()
          ..color = borderColor
          ..strokeWidth = 1.0
          ..style = PaintingStyle.stroke
          ..isAntiAlias = true,
      );
    }
    tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
    canvas.restore();
  }

  // --- Blur / pixelate ------------------------------------------------------

  /// Obscures a region. When [baseImage] is supplied (export path) the actual
  /// pixels are resampled; on the live canvas the widget layer applies a real
  /// BackdropFilter and this only paints the region outline.
  static void _drawBlur(
    Canvas canvas,
    Annotation ann, {
    ui.Image? baseImage,
    Rect? imageRect,
  }) {
    if (ann.startPoint == null || ann.endPoint == null) return;
    final rect = Rect.fromPoints(ann.startPoint!, ann.endPoint!);
    // Gene - Nov, 20, 2026: Lower min blur span & proportional corner radius for zoomed captures.
    // Old: if (rect.width < 1 || rect.height < 1) return;
    if (rect.width < 0.05 || rect.height < 0.05) return;

    final defaultRadius = math.min(4.0, rect.shortestSide * 0.15);
    final rrect = RRect.fromRectAndRadius(
      rect,
      Radius.circular(ann.borderRadius > 0 ? ann.borderRadius : defaultRadius),
    );

    // Solid Blackout Redaction Bar (Security Standard for Passwords / PII)
    if (ann.blurType == BlurType.solid) {
      final fillPaint = Paint()
        ..color = Colors.black.withValues(alpha: ann.opacity)
        ..style = PaintingStyle.fill
        ..isAntiAlias = true;
      canvas.drawRRect(rrect, fillPaint);
      return;
    }

    if (baseImage != null && imageRect != null) {
      canvas.save();
      canvas.clipRRect(rrect);

      // Gene - Nov, 23, 2026: Undo canvas rotation inside the clip so rotated blur/pixelate boxes sample aligned source pixels.
      Rect sampleRect = rect;
      if (ann.rotation != 0.0) {
        final center = rect.center;
        canvas.translate(center.dx, center.dy);
        canvas.rotate(-ann.rotation);
        canvas.translate(-center.dx, -center.dy);
        sampleRect = _boundsThrough([
          toCanvasSpace(ann, rect.topLeft),
          toCanvasSpace(ann, rect.topRight),
          toCanvasSpace(ann, rect.bottomLeft),
          toCanvasSpace(ann, rect.bottomRight),
        ], 0.0);
      }

      if (ann.blurType == BlurType.pixelate) {
        // Old: _paintPixelated(canvas, ann, rect, baseImage, imageRect);
        _paintPixelated(canvas, ann, sampleRect, baseImage, imageRect);
      } else {
        if (imageRect.width > 0 && imageRect.height > 0) {
          final margin = ann.blurStrength * 3.0;
          // Old: final expanded = rect.inflate(margin).intersect(imageRect);
          final expanded = sampleRect.inflate(margin).intersect(imageRect);
          if (!expanded.isEmpty) {
            final scaleX = baseImage.width / imageRect.width;
            final scaleY = baseImage.height / imageRect.height;
            final srcLeft = ((expanded.left - imageRect.left) * scaleX).clamp(
              0.0,
              baseImage.width.toDouble(),
            );
            final srcTop = ((expanded.top - imageRect.top) * scaleY).clamp(
              0.0,
              baseImage.height.toDouble(),
            );
            final srcRight = ((expanded.right - imageRect.left) * scaleX).clamp(
              srcLeft,
              baseImage.width.toDouble(),
            );
            final srcBottom = ((expanded.bottom - imageRect.top) * scaleY)
                .clamp(srcTop, baseImage.height.toDouble());
            final srcRect = Rect.fromLTRB(srcLeft, srcTop, srcRight, srcBottom);
            canvas.saveLayer(
              // Old: rect,
              sampleRect,
              Paint()
                ..imageFilter = ui.ImageFilter.blur(
                  sigmaX: ann.blurStrength,
                  sigmaY: ann.blurStrength,
                  tileMode: TileMode.clamp,
                ),
            );
            canvas.drawImageRect(
              baseImage,
              srcRect,
              expanded,
              Paint()..filterQuality = FilterQuality.high,
            );
            canvas.restore();
          }
        }
      }
      canvas.restore();
      return;
    }

    // No source pixels available (live canvas) — the region is handled by the
    // BackdropFilter layer underneath, so only hint the boundary.
    canvas.drawRRect(
      rrect,
      Paint()
        // Old: ..color = AppDefaults.defaultColor.withValues(alpha: 0.45)
        ..color = Colors.black54
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke,
    );
  }

  /// Mosaic obscuration: downsamples the region then scales it back up with
  /// nearest-neighbour filtering so the original content is unrecoverable.
  static void _paintPixelated(
    Canvas canvas,
    Annotation ann,
    Rect rect,
    ui.Image baseImage,
    Rect imageRect,
  ) {
    // Gene - Nov, 20, 2026: Allow sub-pixel canvas block sizes so pixelated blur stays crisp on long zoomed captures.
    // Old: final block = ann.blurStrength.clamp(2.0, 60.0);
    final block = ann.blurStrength.clamp(0.05, 60.0);
    final scaleX = baseImage.width / imageRect.width;
    final scaleY = baseImage.height / imageRect.height;

    // Source rectangle in native image pixels.
    final srcLeft = ((rect.left - imageRect.left) * scaleX).clamp(
      0.0,
      baseImage.width.toDouble(),
    );
    final srcTop = ((rect.top - imageRect.top) * scaleY).clamp(
      0.0,
      baseImage.height.toDouble(),
    );
    final srcRight = ((rect.right - imageRect.left) * scaleX).clamp(
      0.0,
      baseImage.width.toDouble(),
    );
    final srcBottom = ((rect.bottom - imageRect.top) * scaleY).clamp(
      0.0,
      baseImage.height.toDouble(),
    );
    if (srcRight - srcLeft < 1 || srcBottom - srcTop < 1) return;

    final cols = math.max(1, (rect.width / block).floor());
    final rows = math.max(1, (rect.height / block).floor());
    final cellW = rect.width / cols;
    final cellH = rect.height / rows;
    final srcCellW = (srcRight - srcLeft) / cols;
    final srcCellH = (srcBottom - srcTop) / rows;

    final paint = Paint()
      ..filterQuality = FilterQuality.none
      ..isAntiAlias = false;
    for (int r = 0; r < rows; r++) {
      for (int c = 0; c < cols; c++) {
        // Sample one source pixel per block and stretch it across the cell.
        final sampleX = (srcLeft + srcCellW * (c + 0.5)).clamp(
          0.0,
          baseImage.width - 1.0,
        );
        final sampleY = (srcTop + srcCellH * (r + 0.5)).clamp(
          0.0,
          baseImage.height - 1.0,
        );
        canvas.drawImageRect(
          baseImage,
          Rect.fromLTWH(sampleX, sampleY, 1, 1),
          Rect.fromLTWH(
            rect.left + cellW * c,
            rect.top + cellH * r,
            cellW + 0.5,
            cellH + 0.5,
          ),
          paint,
        );
      }
    }
  }

  // --- Step marker ----------------------------------------------------------

  static void _drawStepMarker(Canvas canvas, Annotation ann) {
    final center = ann.startPoint;
    final step = ann.stepNumber;
    if (center == null || step == null) return;

    final radius = _stepRadius(ann);
    final color = _applyOpacity(ann.color, ann.opacity);

    // Gene - Nov, 20, 2026: Scale badge shadow, border ring, and crisp number typography proportionally on small zoomed step markers.
    // Old:
    // canvas.drawCircle(
    //   center + const Offset(0, 2),
    //   radius,
    //   Paint()
    //     ..color = Colors.black.withValues(alpha: 0.30 * ann.opacity)
    //     ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    // );
    canvas.drawCircle(
      center + Offset(0, radius * 0.12),
      radius,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.30 * ann.opacity)
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          math.max(0.2, radius * 0.25),
        ),
    );

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = color
        ..isAntiAlias = true,
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.92 * ann.opacity)
        // Old: ..strokeWidth = math.max(1.5, radius * 0.12)
        ..strokeWidth = math.max(0.1, radius * 0.12)
        ..style = PaintingStyle.stroke
        ..isAntiAlias = true,
    );

    final targetFont =
        (radius *
                (step >= 100
                    ? 0.72
                    : step >= 10
                    ? 0.88
                    : 1.05))
            .clamp(0.5, 60.0);
    final laidOut = _layoutCrispText(
      text: '$step',
      color: Colors.white.withValues(alpha: ann.opacity),
      fontSize: targetFont,
      fontWeight: FontWeight.bold,
    );

    _paintCrispText(
      canvas,
      laidOut.tp,
      center - Offset(laidOut.size.width / 2, laidOut.size.height / 2),
      laidOut.scale,
    );
  }

  // --- Text -----------------------------------------------------------------

  static void _drawText(Canvas canvas, Annotation ann) {
    final position = ann.startPoint;
    if (position == null || ann.text == null || ann.text!.isEmpty) return;

    final showBg =
        ann.fill && ann.backgroundColor != null && ann.backgroundColor!.a > 0;

    // Gene - Nov, 20, 2026: Render small zoomed-in text via crisp scaled layout + proportional padding & shadow.
    // Old:
    // final tp = _cachedTextPainter(
    //   text: ann.text!,
    //   color: _applyOpacity(ann.color, ann.opacity),
    //   fontSize: ann.fontSize,
    //   fontWeight: FontWeight.w600,
    //   height: 1.25,
    //   hasShadows: !(showBg && !ann.hasShadow),
    // );
    final laidOut = _layoutCrispText(
      text: ann.text!,
      color: _applyOpacity(ann.color, ann.opacity),
      fontSize: ann.fontSize,
      fontWeight: FontWeight.w600,
      height: 1.25,
      hasShadows: !(showBg && !ann.hasShadow),
    );

    if (showBg) {
      final padX = _textPadXFor(ann);
      final padY = _textPadYFor(ann);
      final bgRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          position.dx - padX,
          position.dy - padY,
          laidOut.size.width + padX * 2,
          laidOut.size.height + padY * 2,
        ),
        Radius.circular(ann.borderRadius.clamp(0.0, 32.0)),
      );

      if (ann.hasShadow) {
        final bgShadowScale = (ann.fontSize / 18.0).clamp(0.05, 1.0);
        final shadowPaint = Paint()
          ..color = Colors.black.withValues(alpha: 0.35 * ann.opacity)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 4.0 * bgShadowScale);
        canvas.drawRRect(
          bgRect.shift(Offset(0, 2.0 * bgShadowScale)),
          shadowPaint,
        );
      }

      canvas.drawRRect(
        bgRect,
        Paint()
          ..color = _applyOpacity(ann.backgroundColor!, ann.opacity)
          ..isAntiAlias = true,
      );
    }

    _paintCrispText(canvas, laidOut.tp, position, laidOut.scale);
  }

  // ---------------------------------------------------------------------------
  // Selection chrome (screen only — never part of an export)
  // ---------------------------------------------------------------------------

  // Gene - Nov, 23, 2026: Redesign selection chrome & measurement HUD to use Skeleton dual-contrast ink/onActive halos and per-tool tailored handles (direct endpoints + on-curve apex for linear tools, ring + single scale dot for step markers).
  static void _drawContrastLine(
    Canvas canvas,
    Offset a,
    Offset b,
    SnipTheme t,
    double s,
  ) {
    canvas.drawLine(
      a,
      b,
      Paint()
        ..color = t.onActive.withValues(alpha: 0.9)
        ..strokeWidth = 2.6 / s
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawLine(
      a,
      b,
      Paint()
        ..color = t.ink
        ..strokeWidth = 1.3 / s
        ..strokeCap = StrokeCap.round,
    );
  }

  static void _drawContrastRRect(
    Canvas canvas,
    RRect rrect,
    SnipTheme t,
    double s,
  ) {
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = t.onActive.withValues(alpha: 0.9)
        ..strokeWidth = 2.8 / s
        ..style = PaintingStyle.stroke,
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = t.ink
        ..strokeWidth = 1.4 / s
        ..style = PaintingStyle.stroke,
    );
  }

  static void _drawContrastCircleHandle(
    Canvas canvas,
    Offset center,
    double radius,
    SnipTheme t,
    double s,
  ) {
    canvas.drawCircle(
      center + Offset(0, 1.0 / s),
      radius,
      Paint()..color = Colors.black.withValues(alpha: 0.28),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = t.onActive
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = t.ink
        ..strokeWidth = 1.8 / s
        ..style = PaintingStyle.stroke,
    );
  }

  static void _drawCurveDiamondHandle(
    Canvas canvas,
    Offset center,
    double radius,
    SnipTheme t,
    double s,
  ) {
    final path = Path()
      ..moveTo(center.dx, center.dy - radius)
      ..lineTo(center.dx + radius, center.dy)
      ..lineTo(center.dx, center.dy + radius)
      ..lineTo(center.dx - radius, center.dy)
      ..close();
    canvas.drawPath(
      path.shift(Offset(0, 1.0 / s)),
      Paint()..color = Colors.black.withValues(alpha: 0.28),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = t.ink
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = t.onActive
        ..strokeWidth = 1.8 / s
        ..style = PaintingStyle.stroke,
    );
  }

  // Old:
  // static void paintSelection(
  //   Canvas canvas,
  //   Annotation ann, {
  //   double viewScale = 1.0,
  // }) {
  //   final s = _safeScale(viewScale);
  //   final bounds = selectionRect(ann, viewScale: s);
  //   if (bounds == Rect.zero) return;
  //   ... (old purple box + off-curve amber handle)
  // }
  static void paintSelection(
    Canvas canvas,
    Annotation ann, {
    double viewScale = 1.0,
    SnipTheme? theme,
    bool hideRotationHandle = false,
  }) {
    final s = _safeScale(viewScale);
    final t = theme ?? SnipTheme.light();

    if (isLinearEndpointTool(ann.tool)) {
      final start = ann.startPoint;
      final end = ann.endPoint;
      if (start == null || end == null) return;

      final rotated = ann.rotation != 0.0;
      if (rotated) {
        canvas.save();
        final center = boundingRect(ann).center;
        canvas.translate(center.dx, center.dy);
        canvas.rotate(ann.rotation);
        canvas.translate(-center.dx, -center.dy);
      }

      final handleRadius = 5.5 / s;
      _drawContrastCircleHandle(canvas, start, handleRadius, t, s);
      _drawContrastCircleHandle(canvas, end, handleRadius, t, s);

      if (ann.tool == CanvasTool.arrow) {
        final apex = arrowCurveApex(ann);
        _drawCurveDiamondHandle(canvas, apex, 5.5 / s, t, s);
      }

      if (rotated) canvas.restore();
      return;
    }

    if (ann.tool == CanvasTool.stepMarker) {
      final center = ann.startPoint;
      if (center == null) return;
      final ringRadius = stepSelectionRingRadius(ann, viewScale: s);
      canvas.drawCircle(
        center,
        ringRadius,
        Paint()
          ..color = t.onActive.withValues(alpha: 0.9)
          ..strokeWidth = 2.6 / s
          ..style = PaintingStyle.stroke,
      );
      canvas.drawCircle(
        center,
        ringRadius,
        Paint()
          ..color = t.ink
          ..strokeWidth = 1.3 / s
          ..style = PaintingStyle.stroke,
      );
      _drawContrastCircleHandle(
        canvas,
        stepScaleHandlePosition(ann, viewScale: s),
        4.8 / s,
        t,
        s,
      );
      return;
    }

    final bounds = selectionRect(ann, viewScale: s);
    if (bounds == Rect.zero) return;

    final rotated = ann.rotation != 0.0;
    if (rotated) {
      canvas.save();
      final center = boundingRect(ann).center;
      canvas.translate(center.dx, center.dy);
      canvas.rotate(ann.rotation);
      canvas.translate(-center.dx, -center.dy);
    }

    _drawContrastRRect(
      canvas,
      RRect.fromRectAndRadius(bounds, Radius.circular(6.0 / s)),
      t,
      s,
    );

    final cornerRadius = 4.8 / s;
    for (final c in [
      bounds.topLeft,
      bounds.topRight,
      bounds.bottomLeft,
      bounds.bottomRight,
    ]) {
      _drawContrastCircleHandle(canvas, c, cornerRadius, t, s);
    }

    if (supportsRotation(ann.tool) && !hideRotationHandle) {
      final topCenter = bounds.topCenter;
      final rotHandle = topCenter - Offset(0, rotationHandleGap / s);
      _drawContrastLine(canvas, topCenter, rotHandle, t, s);
      _drawContrastCircleHandle(canvas, rotHandle, 5.5 / s, t, s);
    }

    if (rotated) canvas.restore();
  }

  /// Live size/angle readout shown while drawing or transforming, like the
  /// dimension HUD in Snagit and Shottr.
  // Old:
  // static void paintMeasurementHud(
  //   Canvas canvas,
  //   Annotation ann, {
  //   double viewScale = 1.0,
  //   double pixelScale = 1.0,
  // }) {
  //   ...
  //   _drawBadge(
  //     canvas,
  //     center: Offset(bounds.center.dx, bounds.top - 16.0 / s),
  //     text: label,
  //     background: AppDefaults.defaultColor,
  //     scale: 1.0 / s,
  //   );
  // }
  static void paintMeasurementHud(
    Canvas canvas,
    Annotation ann, {
    double viewScale = 1.0,
    double pixelScale = 1.0,
    SnipTheme? theme,
  }) {
    final pScale = _safeScale(pixelScale);
    final String label;
    switch (ann.tool) {
      case CanvasTool.shape || CanvasTool.blur:
        final r = boundingRect(ann);
        if (r.width * pScale < 2 && r.height * pScale < 2) return;
        label =
            '${(r.width * pScale).round()} × ${(r.height * pScale).round()}';
      case CanvasTool.line || CanvasTool.arrow:
        if (ann.startPoint == null || ann.endPoint == null) return;
        final d = (ann.endPoint! - ann.startPoint!);
        if (d.distance * pScale < 2) return;
        final deg = (math.atan2(d.dy, d.dx) * 180 / math.pi);
        label = '${(d.distance * pScale).round()} px  ${deg.round()}°';
      default:
        return;
    }

    final s = _safeScale(viewScale);
    final t = theme ?? SnipTheme.light();
    final bounds = ann.rotation != 0.0
        ? rotatedSelectionBounds(ann, viewScale: s)
        : boundingRect(ann);
    final hudY = supportsRotation(ann.tool)
        ? bounds.bottom + 18.0 / s
        : bounds.top - 18.0 / s;
    _drawBadge(
      canvas,
      center: Offset(bounds.center.dx, hudY),
      text: label,
      background: t.ink,
      textColor: t.onActive,
      borderColor: t.onActive.withValues(alpha: 0.45),
      scale: 1.0 / s,
    );
  }
}
