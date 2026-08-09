import 'package:flutter/material.dart';

enum CanvasTool {
  select,
  pen,
  arrow,
  line,
  rectangle,
  oval,
  highlight,
  stepMarker,
  text,
  blur,
  crop,
}

class AppColors {
  // Vibrant Warm Sunset Orange Theme
  static const Color accent = Color(0xFFFF6600);
  static const Color accentHover = Color(0xFFFF8533);
  static const Color blueAccent = Color(0xFF0EA5E9);
  static const Color greenAccent = Color(0xFF10B981);

  // Dark Warm Slate Theme Colors
  static const Color darkBg = Color(0xFF1C1917);
  static const Color darkSurface = Color(0xFF292524);
  static const Color darkSurfaceVariant = Color(0xFF383533);
  static const Color sidebarBg = Color(0xFF181514);
  static const Color canvasBg = Color(0xFF12100F);

  // Light Warm Ivory Theme Colors
  static const Color lightBg = Color(0xFFFFFBF7);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurfaceVariant = Color(0xFFF5EFE8);
  static const Color sidebarBgLight = Color(0xFFFAF4ED);
  static const Color canvasBgLight = Color(0xFFEFE8E0);

  // Rich Orange & Complementary Annotation Palette
  static const List<Color> palette = [
    Color(0xFFFF6600), // Vibrant Sunset Orange
    Color(0xFFFF3D00), // Deep Amber Orange
    Color(0xFFFFB300), // Golden Yellow
    Color(0xFFE53935), // Crimson Red
    Color(0xFF10B981), // Emerald Green
    Color(0xFF0EA5E9), // Sky Blue
    Color(0xFF8B5CF6), // Deep Violet
    Color(0xFFFFFFFF), // White
    Color(0xFF000000), // Black
  ];
}

class AppDefaults {
  static const double defaultStrokeWidth = 4.0;
  static const double defaultFontSize = 18.0;
  static const Color defaultColor = Color(0xFFFF6600);
}
