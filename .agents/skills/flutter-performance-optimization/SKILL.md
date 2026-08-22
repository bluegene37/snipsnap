---
name: flutter-performance-optimization
description: >-
  Performance tuning, memory leak prevention, and 60/120 FPS jank elimination in Flutter.
  Use when optimizing widget rebuilds, managing native ui.Image lifecycles, using RepaintBoundary, profiling with DevTools, or offloading heavy tasks to isolates.
---

# Flutter Performance Optimization & Memory Safety

This skill provides guidelines and patterns for eliminating UI jank, managing unmanaged memory, and maximizing frame rendering performance.

---

## 1. Frame Budgets & Rebuild Optimization

### 1.1 Frame Timing
- **60 Hz Target**: 16.6ms per frame.
- **120 Hz Target**: 8.3ms per frame.

### 1.2 Minimizing Subtree Rebuilds
- Use `const` constructors on stateless widgets wherever possible to enable compile-time subtree caching.
- Break large widget trees into smaller private `StatelessWidget` classes rather than helper methods returning `Widget`.
- Use `RepaintBoundary` around high-frequency animated or vector-drawn canvas widgets to isolate their layer paint passes from static background layers.

```dart
// ✅ Correct: Isolates screenshot layer from vector drawing layer
Stack(
  children: [
    RepaintBoundary(
      child: ScreenshotBackground(image: image),
    ),
    RepaintBoundary(
      child: CustomPaint(
        painter: ActiveAnnotationVectorPainter(annotations: annotations),
      ),
    ),
  ],
)
```

---

## 2. Unmanaged Native Memory Lifecycle

`dart:ui` objects such as `ui.Image`, `ui.PictureRecorder`, and `ui.Codec` allocate memory in the native graphics engine (Skia / Impeller) outside the Dart Garbage Collector's scope.

### Rules:
1. **Explicit Disposal**: Always call `image.dispose()` when an active bitmap or draft buffer is replaced or removed.
2. **Never store raw `ui.Image` in history**: Store lightweight vector coordinates or compressed `Uint8List` PNG bytes instead.
3. **Controller & Subscription Cleanup**: Always dispose `TextEditingController`, `AnimationController`, `ScrollController`, `FocusNode`, `StreamSubscription`, and `Timer` in `dispose()`.

```dart
@override
void dispose() {
  _uiImage?.dispose();
  _uiImage = null;
  _debounceTimer?.cancel();
  _textController.dispose();
  super.dispose();
}
```

---

## 3. Background Isolate Concurrency

Never run heavy image manipulation, large JSON parsing, or database encryption on the main UI isolate.

```dart
// Run heavy image resizing / encoding in background isolate
Future<Uint8List> compressImageInBackground(Uint8List rawBytes) async {
  return compute(_encodePngWorker, rawBytes);
}

Uint8List _encodePngWorker(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return bytes;
  return Uint8List.fromList(img.encodePng(decoded, level: 6));
}
```

---

## 4. Diagnostics & Profiling

1. Run Flutter in **Profile Mode** (not Debug Mode) when benchmarking performance:
   ```bash
   flutter run --profile -d macos
   ```
2. Open Dart DevTools:
   - **Performance Tab**: Inspect frame timeline, UI thread work, and Raster thread work.
   - **Memory Tab**: Track heap allocation snapshots and verify native image count does not climb steadily.
