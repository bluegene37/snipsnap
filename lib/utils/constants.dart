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
  // Electric Violet Theme (Shottr-style Pro Theme)
  static const Color accent = Color(0xFF8B5CF6);
  static const Color accentHover = Color(0xFFA78BFA);
  static const Color blueAccent = Color(0xFF0EA5E9);
  static const Color greenAccent = Color(0xFF10B981);

  // Dark Sleek Slate-Violet Theme Colors
  static const Color darkBg = Color(0xFF13111C);
  static const Color darkSurface = Color(0xFF1E1B2E);
  static const Color darkSurfaceVariant = Color(0xFF2D2942);
  static const Color sidebarBg = Color(0xFF161424);
  static const Color canvasBg = Color(0xFF0F0D17);

  // Light Ivory-Violet Theme Colors
  static const Color lightBg = Color(0xFFFBFBFE);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurfaceVariant = Color(0xFFF3F0FA);
  static const Color sidebarBgLight = Color(0xFFF7F5FC);
  static const Color canvasBgLight = Color(0xFFEFEBF7);

  // Electric Violet & Complementary Annotation Palette
  static const List<Color> palette = [
    Color(0xFF8B5CF6), // Electric Violet (Shottr Purple)
    Color(0xFF7C3AED), // Royal Deep Purple
    Color(0xFFEC4899), // Neon Pink
    Color(0xFFEF4444), // Crimson Red
    Color(0xFFF59E0B), // Warm Amber
    Color(0xFF10B981), // Emerald Green
    Color(0xFF0EA5E9), // Sky Blue
    Color(0xFFFFFFFF), // Pure White
    Color(0xFF000000), // Pure Black
  ];
}

class AppDefaults {
  static const double defaultStrokeWidth = 4.0;
  static const double defaultFontSize = 18.0;
  static const Color defaultColor = Color(0xFF8B5CF6);

  // Line Thickness Presets
  static const double strokeWidthThin = 2.0;
  static const double strokeWidthMedium = 4.0;
  static const double strokeWidthThick = 8.0;
  static const double strokeWidthHeavy = 14.0;
}

