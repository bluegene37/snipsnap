import 'package:flutter/material.dart';
import '../utils/constants.dart';

class ToolProperties {
  final Color activeColor;
  final double strokeWidth;
  final double opacity;
  final double fontSize;
  final bool isFilled;
  final Color textBackgroundColor;
  final int stepCounter;
  final double blurRadius;

  const ToolProperties({
    required this.activeColor,
    this.strokeWidth = 3.0,
    this.opacity = 1.0,
    this.fontSize = 18.0,
    this.isFilled = false,
    this.textBackgroundColor = Colors.transparent,
    this.stepCounter = 1,
    this.blurRadius = 12.0,
  });

  ToolProperties copyWith({
    Color? activeColor,
    double? strokeWidth,
    double? opacity,
    double? fontSize,
    bool? isFilled,
    Color? textBackgroundColor,
    int? stepCounter,
    double? blurRadius,
  }) {
    return ToolProperties(
      activeColor: activeColor ?? this.activeColor,
      strokeWidth: strokeWidth ?? this.strokeWidth,
      opacity: opacity ?? this.opacity,
      fontSize: fontSize ?? this.fontSize,
      isFilled: isFilled ?? this.isFilled,
      textBackgroundColor: textBackgroundColor ?? this.textBackgroundColor,
      stepCounter: stepCounter ?? this.stepCounter,
      blurRadius: blurRadius ?? this.blurRadius,
    );
  }

  static Map<CanvasTool, ToolProperties> createDefaults() {
    return {
      CanvasTool.select: const ToolProperties(activeColor: AppColors.accent),
      CanvasTool.pen: const ToolProperties(activeColor: Color(0xFFEF4444), strokeWidth: 3.0, opacity: 1.0),
      CanvasTool.arrow: const ToolProperties(activeColor: AppColors.accent, strokeWidth: 3.5, opacity: 1.0),
      CanvasTool.rectangle: const ToolProperties(activeColor: Color(0xFF0EA5E9), strokeWidth: 3.0, isFilled: false, opacity: 1.0),
      CanvasTool.oval: const ToolProperties(activeColor: Color(0xFF8B5CF6), strokeWidth: 3.0, isFilled: false, opacity: 1.0),
      CanvasTool.text: const ToolProperties(activeColor: Colors.white, fontSize: 18.0, textBackgroundColor: Color(0xCC000000), opacity: 1.0),
      CanvasTool.stepMarker: const ToolProperties(activeColor: AppColors.accent, fontSize: 16.0, stepCounter: 1, opacity: 1.0),
      CanvasTool.highlight: const ToolProperties(activeColor: Color(0x99FFEB3B), strokeWidth: 22.0, opacity: 0.6),
      CanvasTool.blur: const ToolProperties(activeColor: Colors.grey, blurRadius: 14.0, opacity: 1.0),
      CanvasTool.ruler: const ToolProperties(activeColor: Color(0xFFF59E0B), strokeWidth: 2.5, opacity: 1.0),
      CanvasTool.crop: const ToolProperties(activeColor: AppColors.accent),
    };
  }
}
