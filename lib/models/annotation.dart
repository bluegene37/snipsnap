import 'package:flutter/material.dart';
import '../utils/constants.dart';

class Annotation {
  final String id;
  final CanvasTool tool;
  final Color color;
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

  Annotation({
    required this.id,
    required this.tool,
    required this.color,
    this.strokeWidth = 4.0,
    this.points = const [],
    this.startPoint,
    this.endPoint,
    this.text,
    this.fontSize = 18.0,
    this.stepNumber,
    this.fill = false,
    this.rect,
    this.opacity = 1.0,
  });

  Annotation copyWith({
    String? id,
    CanvasTool? tool,
    Color? color,
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
  }) {
    return Annotation(
      id: id ?? this.id,
      tool: tool ?? this.tool,
      color: color ?? this.color,
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
    );
  }
}
