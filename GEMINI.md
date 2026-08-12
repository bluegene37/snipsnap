# Snipsnap Codebase Rules & Standards

## Overview
Snipsnap is a desktop screen capture, annotation, and image editing application inspired by tools like Snagit and Shottr. Built with Flutter, it handles high-resolution display captures, rich vector annotations, canvas framing, OCR, screen pinning, and multi-format exports.

---

## 1. Architectural Principles

### 1.1 Model-Painter Decoupling
- **Annotation Models (`lib/models/`)**: Annotation shapes must be pure Dart data classes (immutable or value-equality based) with JSON/Drift serialization support.
- **Painters (`lib/views/components/`)**: Custom painters consume annotation models. Do NOT bake business logic or state mutations inside `CustomPainter.paint()`.
- **Tool Strategies**: Each drawing tool (Arrow, Rectangle, Oval, Text Callout, Step Counter, Highlighter, Blur/Pixelate, Ruler) should be implemented as a clean strategy class implementing a unified `ToolHandler` interface.

### 1.2 Desktop Window & Canvas Management
- **High-DPI Awareness**: Always scale canvas coordinates by `MediaQuery.of(context).devicePixelRatio` or the native display pixel ratio when sampling images or setting pixel dimensions.
- **Screen Pin Overlay**: Pinned screenshot windows must run as borderless, always-on-top windows using `window_manager`. Always clean up window resources when pins are closed.
- **Transparent Overlays**: Region capture overlay windows must have transparent background styling and handle multi-monitor coordinate offsets accurately.

---

## 2. Performance & Memory Guidelines

### 2.1 `ui.Image` Lifecycle & Memory Safety
- `ui.Image` instances derived from `RenderRepaintBoundary` or native screen capture buffers consume unmanaged native memory.
- **Mandatory**: Always call `image.dispose()` explicitly when an image frame or draft bitmap is no longer active.
- Avoid storing raw `ui.Image` objects in persistent undo stacks. Store PNG `Uint8List` bytes or shape vector paths instead.

### 2.2 Repaint Isolation
- Wrap heavy canvas elements (e.g., the base screenshot layer vs. active interactive annotation vector layer) in separate `RepaintBoundary` widgets.
- This prevents re-rendering the entire high-resolution background screenshot on every mouse move gesture during drawing.

---

## 3. State & History Management

### 3.1 Undo / Redo Engine
- History actions must be recorded as discrete transactions (e.g., `AddAnnotationAction`, `DeleteAnnotationAction`, `ModifyTransformAction`, `CropCanvasAction`).
- Ensure state updates trigger efficient UI updates without full screen rebuilds where possible.

### 3.2 Database Integrity (Drift)
- Any persistent schema changes in `lib/database/` require incrementing the database version and writing corresponding migration strategies.
- Run `dart run build_runner build --delete-conflicting-outputs` after updating Drift table definitions.

---

## 4. Platform & Security Rules

- **macOS Permissions**: Screen Recording and Accessibility permissions must be checked gracefully. Provide user-friendly prompts when permissions are missing.
- **Global Hotkeys**: Use `hotkey_manager` safely, unregistering hotkeys during disposal or application teardown.
