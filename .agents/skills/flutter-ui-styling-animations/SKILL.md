---
name: flutter-ui-styling-animations
description: >-
  Advanced UI layout, CustomPainter graphics, and animation techniques in Flutter.
  Use when creating responsive/adaptive layouts, building CustomPainters, configuring Material 3/Cupertino themes, or implementing fluid 60/120fps animations.
---

# Flutter UI, CustomPainter & Animations

This skill outlines design and engineering practices for building high-fidelity Flutter UIs, vector canvas painters, dynamic theme systems, and performant animations.

---

## 1. Responsive & Adaptive Multi-Platform Layouts

### 1.1 Multi-Screen Adaptation
- Use `LayoutBuilder` to switch between compact, medium, and expanded desktop/mobile layouts:
  ```dart
  LayoutBuilder(
    builder: (context, constraints) {
      final isCompact = constraints.maxWidth < 900;
      return Row(
        children: [
          if (!isCompact) const NavigationSidebar(),
          Expanded(child: MainContentArea()),
        ],
      );
    },
  )
  ```
- **High-DPI Scaling**: Canvas coordinate math must always account for `MediaQuery.of(context).devicePixelRatio` or display scale factors.

---

## 2. Advanced `CustomPainter` Vector Rendering

### 2.1 Decoupling & Coordinate Spaces
- Never store presentation logic or mutable state inside `CustomPainter.paint(Canvas canvas, Size size)`.
- Explicitly distinguish between **Canvas Space (logical points)** and **Image Space (native pixels)**.

### 2.2 Vector Drawing Patterns
```dart
class AnnotationPainter extends CustomPainter {
  final List<Annotation> annotations;
  final double zoomScale;

  AnnotationPainter({required this.annotations, required this.zoomScale});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(zoomScale);

    for (final ann in annotations) {
      final paint = Paint()
        ..color = ann.color.withValues(alpha: ann.opacity)
        ..strokeWidth = ann.strokeWidth
        ..style = ann.isFilled ? PaintingStyle.fill : PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      // Draw vector geometry
      canvas.drawRect(ann.rect, paint);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant AnnotationPainter oldDelegate) {
    return oldDelegate.zoomScale != zoomScale ||
        !listEquals(oldDelegate.annotations, annotations);
  }
}
```

---

## 3. Dynamic Theming (Material 3 & ThemeExtension)

### 3.1 ColorScheme & Theme Tokens
- Build predictable themes with semantic tokens (`surface`, `surfaceRaised`, `ink`, `border`, `emphasis`, `danger`).
- Support both Light and Dark modes with automatic contrast validation.

---

## 4. Fluid Animations

### 4.1 Implicit vs Explicit Animations
- **Implicit Animations** (`AnimatedContainer`, `AnimatedOpacity`, `AnimatedSwitcher`): Best for simple state transitions (e.g. sidebar expand/collapse, button hover).
- **Explicit Animations** (`AnimationController`, `CurvedAnimation` with `SingleTickerProviderStateMixin`): Best for continuous gestures, physics springs, rotating progress, or multi-step staggered sequences.

```dart
class PulsingBadge extends StatefulWidget {
  const PulsingBadge({super.key});

  @override
  State<PulsingBadge> createState() => _PulsingBadgeState();
}

class _PulsingBadgeState extends State<PulsingBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  late final Animation<double> _scale = Tween<double>(
    begin: 0.95,
    end: 1.05,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(scale: _scale, child: const Icon(Icons.lens, size: 12));
  }
}
```
