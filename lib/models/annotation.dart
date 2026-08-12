import 'package:flutter/material.dart';
import '../utils/constants.dart';

class Annotation {
  final String id;
  final CanvasTool tool;
  final Color color;
  final Color? backgroundColor;
  final double strokeWidth;
  final List<Offset> points;
  final Offset? startPoint;
  final Offset? endPoint;
  final String? text;
  final double fontSize;
  final int? stepNumber;
  final bool fill;
  final Rect? rect;
  final double opacity;
  final double rotation; // In radians (0.0 = 0 degrees)
  final double borderRadius;
  final LineStyle lineStyle;
  final BlurType blurType;
  final bool isDoubleArrow;

  Annotation({
    required this.id,
    required this.tool,
    required this.color,
    this.backgroundColor,
    this.strokeWidth = 4.0,
    this.points = const [],
    this.startPoint,
    this.endPoint,
    this.text,
    this.fontSize = 18.0,
    this.stepNumber,
    this.fill = false,
    this.rect,
    double opacity = 1.0,
    this.rotation = 0.0,
    this.borderRadius = 8.0,
    this.lineStyle = LineStyle.solid,
    this.blurType = BlurType.gaussian,
    this.isDoubleArrow = false,
  })  : opacity = opacity.clamp(0.0, 1.0),
        assert(strokeWidth > 0, 'strokeWidth must be > 0'),
        assert(fontSize > 0, 'fontSize must be > 0');

  Annotation copyWith({
    String? id,
    CanvasTool? tool,
    Color? color,
    Color? backgroundColor,
    double? strokeWidth,
    List<Offset>? points,
    Offset? startPoint,
    Offset? endPoint,
    String? text,
    double? fontSize,
    int? stepNumber,
    bool? fill,
    Rect? rect,
    double? opacity,
    double? rotation,
    double? borderRadius,
    LineStyle? lineStyle,
    BlurType? blurType,
    bool? isDoubleArrow,
  }) {
    return Annotation(
      id: id ?? this.id,
      tool: tool ?? this.tool,
      color: color ?? this.color,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      strokeWidth: strokeWidth ?? this.strokeWidth,
      points: points ?? this.points,
      startPoint: startPoint ?? this.startPoint,
      endPoint: endPoint ?? this.endPoint,
      text: text ?? this.text,
      fontSize: fontSize ?? this.fontSize,
      stepNumber: stepNumber ?? this.stepNumber,
      fill: fill ?? this.fill,
      rect: rect ?? this.rect,
      opacity: opacity ?? this.opacity,
      rotation: rotation ?? this.rotation,
      borderRadius: borderRadius ?? this.borderRadius,
      lineStyle: lineStyle ?? this.lineStyle,
      blurType: blurType ?? this.blurType,
      isDoubleArrow: isDoubleArrow ?? this.isDoubleArrow,
    );
  }
}
