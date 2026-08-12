---
name: screenshot-editor-domain
description: >-
  Provides domain-specific patterns, algorithms, and guidelines for building Snagit/Shottr features in Flutter.
  Use when implementing canvas tools (arrows, text, step badges, blur, crop), floating screen pins, OCR text extraction,
  canvas padding & shadows, color picker eyedropper, pixel ruler, or image export logic.
---

# Screenshot Editor & Annotation Domain Guide

This skill provides design patterns, formulas, and architecture guidelines for implementing feature-rich screen capture and image annotation capabilities (similar to Snagit, Shottr, and CleanShot) in Flutter desktop applications.

---

## 1. Core Feature Capabilities Matrix

| Feature Category | Description | Implementation Strategy |
| :--- | :--- | :--- |
| **Region Selection Overlay** | Interactive full-screen capture canvas with region drag, auto-snapping to window boundaries, magnifier loupe, and pixel coordinates display. | Borderless transparent window with `Listener` / `GestureDetector`. Uses `window_manager` + native screen bounds. |
| **Vector Annotations** | Arrow, Rectangle, Oval, Step Badges (1-2-3), Text Callouts, Highlighter, Obscure/Blur, Ruler. | Pure model classes + `CustomPainter` rendering layer with interactive selection handles. |
| **Shottr Screen Pinning** | Pinning captured snapshot on top of all desktop windows with scale, opacity, and quick action controls. | Separate borderless floating window (`alwaysOnTop: true`). |
| **Clean Canvas Framing** | Adding customizable canvas padding, smooth rounded corners, drop shadows, and solid/gradient background fills. | Outer `CustomPainter` or composited `Stack` wrapping the image before export. |
| **OCR & Text Extraction** | Extracting editable text from captured image regions. | Image cropping + OCR pipeline (e.g. Tesseract / platform OCR bridge). |
| **Pixel Ruler & Color Picker** | Measuring distances in pixels and picking RGB/Hex colors. | Distance formula along line path + pixel color sampling from bitmap byte buffer. |

---

## 2. Vector Canvas Annotation Engine

### 2.1 Shape Model Hierarchy
Keep models pure and serializable:

```dart
abstract class AnnotationModel {
  final String id;
  final Rect bounds;
  final Color color;
  final double strokeWidth;
  final double opacity;
  final bool isSelected;

  AnnotationModel({
    required this.id,
    required this.bounds,
    required this.color,
    this.strokeWidth = 3.0,
    this.opacity = 1.0,
    this.isSelected = false,
  });

  Map<String, dynamic> toJson();
  AnnotationModel copyWith({bool? isSelected, Rect? bounds, Color? color, double? strokeWidth});
}
```

### 2.2 Interactive Selection Handles
When an annotation is selected, render 8 control handles (`top-left`, `top-center`, `top-right`, `middle-left`, `middle-right`, `bottom-left`, `bottom-center`, `bottom-right`) plus a rotation handle.

Handle Hit-Test Radius: Recommended hit target size is **12x12 px** visual handle, with **20x20 px** touch/click hit radius for easy grabbing.

### 2.3 Blur & Pixelation Obscure Tool
To implement privacy redaction without losing performance:
1. **Pixelation Method**: Divide target rectangle into `N x N` grid cells (e.g., 10x10 px cells). Sample the center pixel color of each cell from the base bitmap and paint solid filled rectangles over each grid cell.
2. **Blur Shader Method**: Apply `BackdropFilter` with `ImageFilter.blur(sigmaX: 8, sigmaY: 8)` clipped to the annotation rectangle path.

### 2.4 Auto-Incrementing Step Counter Badges
- Maintain an `int currentStep = 1` in the active tool state.
- Each click places a circular badge with number `1`, `2`, `3`, etc., and increments `currentStep`.
- Badges support drag re-ordering and re-numbering.

---

## 3. Shottr-Style Floating Screen Pins

To create a floating screen pin:
1. Crop the selected region bitmap into a `ui.Image` or `Uint8List`.
2. Save to temporary storage or pass via window initialization payload.
3. Spawn or configure a floating borderless window:
   ```dart
   await windowManager.setAsFrameless();
   await windowManager.setAlwaysOnTop(true);
   await windowManager.setHasShadow(true);
   await windowManager.show();
   ```
4. Support keyboard shortcuts inside pin window:
   - `Esc`: Close pin window.
   - `Cmd+C` / `Ctrl+C`: Copy pinned image to clipboard.
   - `Scroll Wheel`: Adjust window zoom / scale.
   - `Cmd + Scroll Wheel`: Adjust window opacity (10% - 100%).

---

## 4. Clean Canvas Framing (Export Styling)

Provide CleanShot/Shottr style canvas backgrounds for social sharing:

```dart
class FramedExportPainter extends CustomPainter {
  final ui.Image sourceImage;
  final double padding;
  final double cornerRadius;
  final double shadowBlur;
  final Color shadowColor;
  final Gradient? backgroundGradient;
  final Color? backgroundColor;

  FramedExportPainter({
    required this.sourceImage,
    this.padding = 40.0,
    this.cornerRadius = 16.0,
    this.shadowBlur = 24.0,
    this.shadowColor = const Color(0x40000000),
    this.backgroundGradient,
    this.backgroundColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Draw Background (Gradient or Solid Fill)
    final bgPaint = Paint();
    if (backgroundGradient != null) {
      bgPaint.shader = backgroundGradient!.createShader(Offset.zero & size);
    } else {
      bgPaint.color = backgroundColor ?? Colors.transparent;
    }
    canvas.drawRect(Offset.zero & size, bgPaint);

    // 2. Compute Inner Image Rect
    final imageRect = Rect.fromLTWH(
      padding,
      padding,
      size.width - (padding * 2),
      size.height - (padding * 2),
    );
    final RRect clipRRect = RRect.fromRectAndRadius(imageRect, Radius.circular(cornerRadius));

    // 3. Draw Soft Drop Shadow
    final shadowPaint = Paint()
      ..color = shadowColor
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, shadowBlur);
    canvas.drawRRect(clipRRect.shift(const Offset(0, 8)), shadowPaint);

    // 4. Clip & Draw Source Image
    canvas.save();
    canvas.clipRRect(clipRRect);
    paintImage(
      canvas: canvas,
      rect: imageRect,
      image: sourceImage,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.high,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant FramedExportPainter oldDelegate) => true;
}
```

---

## 5. Performance Checklist for Snipsnap Editors

- [ ] **Memory Leak Prevention**: Dispose all intermediate `ui.Image` objects after export or canvas resize.
- [ ] **Repaint Boundary Isolation**: Keep background image layer inside its own `RepaintBoundary` separated from active vector stroke drawing.
- [ ] **Coordinate Scaling**: Multiply normalized coordinates `(0.0 - 1.0)` by actual bitmap pixel dimensions when rendering final high-res output.
- [ ] **Drift Transaction Safety**: Wrap bulk annotation saves in `database.transaction(() async { ... })`.
