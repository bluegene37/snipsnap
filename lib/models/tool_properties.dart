import 'package:flutter/material.dart';
import '../utils/constants.dart';

const Object _unset = Object();

class ToolProperties {
  final Color activeColor;
  final double strokeWidth;
  final double opacity;
  final double fontSize;
  final bool isFilled;
  final Color? textBackgroundColor;
  final Color? fillColor;
  final int stepCounter;
  final double blurStrength;
  final double borderRadius;
  final ShapeKind shapeKind;
  final LineStyle lineStyle;
  final BlurType blurType;
  final bool isDoubleArrow;
  final bool hasShadow;
  final double fillTolerance;
  final bool isGlobalFill;

  const ToolProperties({
    required this.activeColor,
    this.strokeWidth = 3.0,
    this.opacity = 1.0,
    this.fontSize = 18.0,
    this.isFilled = false,
    this.textBackgroundColor,
    this.fillColor,
    this.stepCounter = 1,
    this.blurStrength = 14.0,
    this.borderRadius = 8.0,
    this.shapeKind = ShapeKind.rectangle,
    this.lineStyle = LineStyle.solid,
    this.blurType = BlurType.gaussian,
    this.isDoubleArrow = false,
    this.hasShadow = false,
    this.fillTolerance = 15.0,
    this.isGlobalFill = false,
  });

  ToolProperties copyWith({
    Color? activeColor,
    double? strokeWidth,
    double? opacity,
    double? fontSize,
    bool? isFilled,
    Object? textBackgroundColor = _unset,
    Object? fillColor = _unset,
    int? stepCounter,
    double? blurStrength,
    double? borderRadius,
    ShapeKind? shapeKind,
    LineStyle? lineStyle,
    BlurType? blurType,
    bool? isDoubleArrow,
    bool? hasShadow,
    double? fillTolerance,
    bool? isGlobalFill,
  }) {
    return ToolProperties(
      activeColor: activeColor ?? this.activeColor,
      strokeWidth: strokeWidth ?? this.strokeWidth,
      opacity: opacity ?? this.opacity,
      fontSize: fontSize ?? this.fontSize,
      isFilled: isFilled ?? this.isFilled,
      textBackgroundColor: identical(textBackgroundColor, _unset)
          ? this.textBackgroundColor
          : textBackgroundColor as Color?,
      fillColor: identical(fillColor, _unset) ? this.fillColor : fillColor as Color?,
      stepCounter: stepCounter ?? this.stepCounter,
      blurStrength: blurStrength ?? this.blurStrength,
      borderRadius: borderRadius ?? this.borderRadius,
      shapeKind: shapeKind ?? this.shapeKind,
      lineStyle: lineStyle ?? this.lineStyle,
      blurType: blurType ?? this.blurType,
      isDoubleArrow: isDoubleArrow ?? this.isDoubleArrow,
      hasShadow: hasShadow ?? this.hasShadow,
      fillTolerance: fillTolerance ?? this.fillTolerance,
      isGlobalFill: isGlobalFill ?? this.isGlobalFill,
    );
  }

  static Map<CanvasTool, ToolProperties> createDefaults() {
    return {
      CanvasTool.select: const ToolProperties(activeColor: AppColors.accent),
      CanvasTool.pen: const ToolProperties(
          activeColor: Color(0xFFEF4444), strokeWidth: 3.0, opacity: 1.0, hasShadow: true),
      CanvasTool.arrow: const ToolProperties(
          activeColor: AppColors.accent, strokeWidth: 3.5, opacity: 1.0, hasShadow: true),
      CanvasTool.line: const ToolProperties(
          activeColor: AppColors.accent, strokeWidth: 3.0, opacity: 1.0, hasShadow: true),
      CanvasTool.shape: const ToolProperties(
          activeColor: Color(0xFF0EA5E9),
          strokeWidth: 3.0,
          isFilled: false,
          opacity: 1.0,
          shapeKind: ShapeKind.rectangle),
      CanvasTool.text: const ToolProperties(
          activeColor: Colors.white,
          fontSize: 18.0,
          isFilled: true,
          textBackgroundColor: Color(0xCC000000),
          opacity: 1.0),
      CanvasTool.stepMarker: const ToolProperties(
          activeColor: AppColors.accent, fontSize: 16.0, stepCounter: 1, opacity: 1.0),
      CanvasTool.highlight: const ToolProperties(
          activeColor: Color(0xFFFDE047), strokeWidth: 18.0, opacity: 1.0),
      CanvasTool.blur: const ToolProperties(
          activeColor: Colors.grey, blurStrength: 14.0, opacity: 1.0, blurType: BlurType.pixelate),
      CanvasTool.ruler: const ToolProperties(
          activeColor: Color(0xFFF59E0B), strokeWidth: 2.0, opacity: 1.0),
      CanvasTool.fill: const ToolProperties(
          activeColor: Color(0xFFEF4444),
          isFilled: true,
          fillTolerance: 15.0,
          opacity: 1.0,
          isGlobalFill: false),
      CanvasTool.colorPicker: const ToolProperties(activeColor: AppColors.accent),
      CanvasTool.crop: const ToolProperties(activeColor: AppColors.accent),
    };
  }
}
