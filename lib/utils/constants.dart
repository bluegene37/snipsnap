import 'package:flutter/material.dart';

/// Tools whose stroke weight is set by dragging the mark itself, not by the
/// properties slider.
///
/// Dragging a resize handle across one of these changes its thickness (see
/// `EditorCanvas._resizeStroke`), which makes a slider for the same property
/// redundant — so the panel hides it for them, and their weight is free to go
/// well past the range a slider could offer.
const dragSizedStrokeTools = {
  CanvasTool.line,
  CanvasTool.arrow,
  CanvasTool.highlight,
  CanvasTool.ruler,
};

enum CanvasTool {
  select,
  pen,
  arrow,
  line,
  /// Unified vector shape tool. The concrete outline is chosen with
  /// [ShapeKind] — this replaced the separate rectangle and oval tools.
  shape,
  highlight,
  stepMarker,
  text,
  blur,
  ruler,
  crop,
  fill,
  colorPicker,

  /// Extracts text from the capture using the platform OCR engine.
  ocr,
}

/// Outlines available to [CanvasTool.shape].
enum ShapeKind {
  rectangle,
  ellipse,
  triangle,
  diamond,
  pentagon,
  hexagon,
  star,
  speechBubble,
}

extension ShapeKindDisplay on ShapeKind {
  String get label => switch (this) {
        ShapeKind.rectangle => 'Rectangle',
        ShapeKind.ellipse => 'Ellipse',
        ShapeKind.triangle => 'Triangle',
        ShapeKind.diamond => 'Diamond',
        ShapeKind.pentagon => 'Pentagon',
        ShapeKind.hexagon => 'Hexagon',
        ShapeKind.star => 'Star',
        ShapeKind.speechBubble => 'Speech Bubble',
      };

  IconData get icon => switch (this) {
        ShapeKind.rectangle => Icons.crop_square_rounded,
        ShapeKind.ellipse => Icons.circle_outlined,
        ShapeKind.triangle => Icons.change_history_rounded,
        ShapeKind.diamond => Icons.diamond_outlined,
        ShapeKind.pentagon => Icons.pentagon_outlined,
        ShapeKind.hexagon => Icons.hexagon_outlined,
        ShapeKind.star => Icons.star_border_rounded,
        ShapeKind.speechBubble => Icons.chat_bubble_outline_rounded,
      };
}

enum LineStyle {
  solid,
  dashed,
}

enum BlurType {
  gaussian,
  pixelate,
  solid,
}

class AppColors {
  // Annotation swatch palette — user data, rendered in real colour. Not
  // chrome, and not part of the skeleton token system in lib/utils/snip_theme.dart.
  static const List<Color> palette = [
    Color(0xFFEF4444), // Crimson Red
    Color(0xFFF97316), // Vibrant Orange
    Color(0xFFF59E0B), // Warm Amber
    Color(0xFF10B981), // Emerald Green
    Color(0xFF06B6D4), // Cyan
    Color(0xFF0EA5E9), // Sky Blue
    Color(0xFF6366F1), // Royal Indigo
    Color(0xFF8B5CF6), // Electric Violet (Shottr Purple)
    Color(0xFFEC4899), // Neon Pink
    Color(0xFF64748B), // Slate Gray
    Color(0xFFFFFFFF), // Pure White
    Color(0xFF000000), // Pure Black
  ];

  // Shottr & CleanShot Style Canvas Framing Background Gradients
  static const List<Gradient> framingGradients = [
    LinearGradient(
      colors: [Color(0xFF8B5CF6), Color(0xFFEC4899)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ),
    LinearGradient(
      colors: [Color(0xFF0EA5E9), Color(0xFF6366F1)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ),
    LinearGradient(
      colors: [Color(0xFFF59E0B), Color(0xFFEF4444)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ),
    LinearGradient(
      colors: [Color(0xFF10B981), Color(0xFF0EA5E9)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ),
    LinearGradient(
      colors: [Color(0xFF1E1B2E), Color(0xFF0F0D17)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ),
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


