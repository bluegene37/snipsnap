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
  static const Color accent = Color(0xFFFF5E57); // Snagit-style vibrant coral red/orange
  static const Color accentHover = Color(0xFFFF7A74);
  static const Color blueAccent = Color(0xFF38BDF8);
  static const Color greenAccent = Color(0xFF4ADE80);

  // Dark Theme Colors
  static const Color darkBg = Color(0xFF1E1E2E);
  static const Color darkSurface = Color(0xFF252538);
  static const Color darkSurfaceVariant = Color(0xFF2F2F46);
  static const Color sidebarBg = Color(0xFF181825);
  static const Color canvasBg = Color(0xFF11111B);

  // Light Theme Colors
  static const Color lightBg = Color(0xFFF8FAFC);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurfaceVariant = Color(0xFFE2E8F0);
  static const Color sidebarBgLight = Color(0xFFF1F5F9);
  static const Color canvasBgLight = Color(0xFFE5E7EB);

  // Palette for Annotations
  static const List<Color> palette = [
    Color(0xFFFF3B30), // Red
    Color(0xFFFF9500), // Orange
    Color(0xFFFFCC00), // Yellow
    Color(0xFF34C759), // Green
    Color(0xFF007AFF), // Blue
    Color(0xFFAF52DE), // Purple
    Color(0xFF5856D6), // Indigo
    Color(0xFFFFFFFF), // White
    Color(0xFF000000), // Black
  ];
}

class AppDefaults {
  static const double defaultStrokeWidth = 4.0;
  static const double defaultFontSize = 18.0;
  static const Color defaultColor = Color(0xFFFF3B30);
}
