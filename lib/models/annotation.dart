import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../utils/canvas_projection.dart';
import '../utils/constants.dart';

/// Sentinel used by [Annotation.copyWith] so nullable fields can be explicitly
/// cleared (`fillColor: null`) instead of "leave unchanged".
const Object _unset = Object();

class Annotation {
  final String id;
  final CanvasTool tool;

  /// Stroke / primary colour of the annotation.
  final Color color;

  /// Background box colour for text callouts.
  final Color? backgroundColor;

  /// Independent shape fill colour. When null and [fill] is true the stroke
  /// colour is used at a reduced alpha (Snagit/Shottr default behaviour).
  final Color? fillColor;

  final double strokeWidth;
  final List<Offset> points;
  final Offset? startPoint;
  final Offset? endPoint;

  /// Optional Bezier control point for curved arrows.
  final Offset? controlPoint;

  final String? text;
  final double fontSize;
  final int? stepNumber;
  final bool fill;
  final Rect? rect;
  final double opacity;
  final double rotation; // In radians (0.0 = 0 degrees)
  final double borderRadius;

  /// Which outline a [CanvasTool.shape] annotation draws.
  final ShapeKind shapeKind;

  final LineStyle lineStyle;
  final BlurType blurType;

  /// Gaussian sigma / pixelate block size for blur regions.
  final double blurStrength;

  final bool isDoubleArrow;

  /// Drop shadow behind the annotation — keeps markup legible on busy
  /// screenshots (standard in Snagit, CleanShot and Shottr).
  final bool hasShadow;

  Annotation({
    required this.id,
    required this.tool,
    required this.color,
    this.backgroundColor,
    this.fillColor,
    this.strokeWidth = 4.0,
    this.points = const [],
    this.startPoint,
    this.endPoint,
    this.controlPoint,
    this.text,
    this.fontSize = 18.0,
    this.stepNumber,
    this.fill = false,
    this.rect,
    double opacity = 1.0,
    this.rotation = 0.0,
    this.borderRadius = 8.0,
    this.shapeKind = ShapeKind.rectangle,
    this.lineStyle = LineStyle.solid,
    this.blurType = BlurType.gaussian,
    double blurStrength = 14.0,
    this.isDoubleArrow = false,
    this.hasShadow = false,
  })  : opacity = opacity.clamp(0.0, 1.0),
        blurStrength = blurStrength.clamp(1.0, 60.0),
        assert(strokeWidth > 0, 'strokeWidth must be > 0'),
        assert(fontSize > 0, 'fontSize must be > 0');

  Annotation copyWith({
    String? id,
    CanvasTool? tool,
    Color? color,
    Object? backgroundColor = _unset,
    Object? fillColor = _unset,
    double? strokeWidth,
    List<Offset>? points,
    Object? startPoint = _unset,
    Object? endPoint = _unset,
    Object? controlPoint = _unset,
    String? text,
    double? fontSize,
    int? stepNumber,
    bool? fill,
    Object? rect = _unset,
    double? opacity,
    double? rotation,
    double? borderRadius,
    ShapeKind? shapeKind,
    LineStyle? lineStyle,
    BlurType? blurType,
    double? blurStrength,
    bool? isDoubleArrow,
    bool? hasShadow,
  }) {
    return Annotation(
      id: id ?? this.id,
      tool: tool ?? this.tool,
      color: color ?? this.color,
      backgroundColor:
          identical(backgroundColor, _unset) ? this.backgroundColor : backgroundColor as Color?,
      fillColor: identical(fillColor, _unset) ? this.fillColor : fillColor as Color?,
      strokeWidth: strokeWidth ?? this.strokeWidth,
      points: points ?? this.points,
      startPoint:
          identical(startPoint, _unset) ? this.startPoint : startPoint as Offset?,
      endPoint: identical(endPoint, _unset) ? this.endPoint : endPoint as Offset?,
      controlPoint: identical(controlPoint, _unset)
          ? this.controlPoint
          : controlPoint as Offset?,
      text: text ?? this.text,
      fontSize: fontSize ?? this.fontSize,
      stepNumber: stepNumber ?? this.stepNumber,
      fill: fill ?? this.fill,
      rect: identical(rect, _unset) ? this.rect : rect as Rect?,
      opacity: opacity ?? this.opacity,
      rotation: rotation ?? this.rotation,
      borderRadius: borderRadius ?? this.borderRadius,
      shapeKind: shapeKind ?? this.shapeKind,
      lineStyle: lineStyle ?? this.lineStyle,
      blurType: blurType ?? this.blurType,
      blurStrength: blurStrength ?? this.blurStrength,
      isDoubleArrow: isDoubleArrow ?? this.isDoubleArrow,
      hasShadow: hasShadow ?? this.hasShadow,
    );
  }

  /// Translate every geometric component of the annotation by [delta].
  Annotation translated(Offset delta) {
    return copyWith(
      startPoint: startPoint == null ? null : startPoint! + delta,
      endPoint: endPoint == null ? null : endPoint! + delta,
      controlPoint: controlPoint == null ? null : controlPoint! + delta,
      points: points.map((p) => p + delta).toList(),
      rect: rect?.shift(delta),
    );
  }

  /// Converts every geometric and scalar dimension from canvas coordinates
  /// into native image pixels.
  Annotation mappedToImageSpace(CanvasProjection p) =>
      _mapped(p.toImage, p.toImageLength);

  /// Inverse of [mappedToImageSpace].
  Annotation mappedToCanvasSpace(CanvasProjection p) =>
      _mapped(p.toCanvas, p.toCanvasLength);

  Annotation _mapped(
    Offset Function(Offset) mapPoint,
    double Function(double) mapLength,
  ) {
    return copyWith(
      startPoint: startPoint == null ? null : mapPoint(startPoint!),
      endPoint: endPoint == null ? null : mapPoint(endPoint!),
      controlPoint: controlPoint == null ? null : mapPoint(controlPoint!),
      points: points.map(mapPoint).toList(),
      rect: rect == null
          ? null
          : Rect.fromPoints(mapPoint(rect!.topLeft), mapPoint(rect!.bottomRight)),
      strokeWidth: mapLength(strokeWidth),
      fontSize: mapLength(fontSize),
      borderRadius: mapLength(borderRadius),
      blurStrength: mapLength(blurStrength),
    );
  }

  /// Extra properties that do not have dedicated database columns. Kept as a
  /// single JSON blob so new tool properties never silently stop persisting.
  Map<String, dynamic> toPropsJson() {
    return {
      'borderRadius': borderRadius,
      'shapeKind': shapeKind.name,
      'lineStyle': lineStyle.name,
      'blurType': blurType.name,
      'blurStrength': blurStrength,
      'isDoubleArrow': isDoubleArrow,
      'hasShadow': hasShadow,
      'rotation': rotation,
      if (controlPoint != null) 'controlPoint': {'x': controlPoint!.dx, 'y': controlPoint!.dy},
      if (backgroundColor != null) 'backgroundColor': backgroundColor!.toARGB32(),
      if (fillColor != null) 'fillColor': fillColor!.toARGB32(),
      if (rect != null)
        'rect': {'l': rect!.left, 't': rect!.top, 'r': rect!.right, 'b': rect!.bottom},
    };
  }

  /// Rebuilds the extra properties written by [toPropsJson] onto this instance.
  Annotation withPropsJson(Map<String, dynamic> map) {
    Rect? parsedRect;
    final rectMap = map['rect'];
    if (rectMap is Map) {
      parsedRect = Rect.fromLTRB(
        (rectMap['l'] as num).toDouble(),
        (rectMap['t'] as num).toDouble(),
        (rectMap['r'] as num).toDouble(),
        (rectMap['b'] as num).toDouble(),
      );
    }

    Offset? parsedControlPoint;
    final cpMap = map['controlPoint'];
    if (cpMap is Map) {
      parsedControlPoint = Offset(
        (cpMap['x'] as num).toDouble(),
        (cpMap['y'] as num).toDouble(),
      );
    }

    return copyWith(
      borderRadius: (map['borderRadius'] as num?)?.toDouble(),
      shapeKind: _enumByName(ShapeKind.values, map['shapeKind'] as String?),
      lineStyle: _enumByName(LineStyle.values, map['lineStyle'] as String?),
      blurType: _enumByName(BlurType.values, map['blurType'] as String?),
      blurStrength: (map['blurStrength'] as num?)?.toDouble(),
      isDoubleArrow: map['isDoubleArrow'] as bool?,
      hasShadow: map['hasShadow'] as bool?,
      rotation: (map['rotation'] as num?)?.toDouble(),
      controlPoint: parsedControlPoint,
      backgroundColor: map.containsKey('backgroundColor')
          ? Color(map['backgroundColor'] as int)
          : backgroundColor,
      fillColor: map.containsKey('fillColor') ? Color(map['fillColor'] as int) : fillColor,
      rect: parsedRect,
    );
  }

  static T? _enumByName<T extends Enum>(List<T> values, String? name) {
    if (name == null) return null;
    for (final v in values) {
      if (v.name == name) return v;
    }
    return null;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Annotation &&
        other.id == id &&
        other.tool == tool &&
        other.color == color &&
        other.backgroundColor == backgroundColor &&
        other.fillColor == fillColor &&
        other.strokeWidth == strokeWidth &&
        listEquals(other.points, points) &&
        other.startPoint == startPoint &&
        other.endPoint == endPoint &&
        other.controlPoint == controlPoint &&
        other.text == text &&
        other.fontSize == fontSize &&
        other.stepNumber == stepNumber &&
        other.fill == fill &&
        other.rect == rect &&
        other.opacity == opacity &&
        other.rotation == rotation &&
        other.borderRadius == borderRadius &&
        other.shapeKind == shapeKind &&
        other.lineStyle == lineStyle &&
        other.blurType == blurType &&
        other.blurStrength == blurStrength &&
        other.isDoubleArrow == isDoubleArrow &&
        other.hasShadow == hasShadow;
  }

  @override
  int get hashCode => Object.hash(
        id,
        tool,
        color,
        backgroundColor,
        fillColor,
        strokeWidth,
        Object.hashAll(points),
        startPoint,
        endPoint,
        controlPoint,
        text,
        fontSize,
        stepNumber,
        fill,
        rect,
        opacity,
        rotation,
        Object.hash(borderRadius, shapeKind, lineStyle, blurType, blurStrength, isDoubleArrow,
            hasShadow),
      );
}
