# SnipSnap Phases 1–3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move annotation geometry into image-pixel space, consolidate the duplicated tool-gesture layer, and add a text-extraction (OCR) tool backed by the OCR engines built into macOS and Windows.

**Architecture:** A `CanvasProjection` value object owns the single conversion between canvas (viewport) coordinates and native image pixels, carrying both points and scalar dimensions. The in-memory annotation list becomes the image-pixel source of truth; `EditorCanvas` converts to canvas space for painting and hit-testing, and converts gesture input back. `AnnotationRenderer` and every hit-test are therefore unchanged — they keep receiving canvas-space annotations exactly as today. OCR sits behind an `OcrEngine` interface with two native implementations over one method channel.

**Tech Stack:** Flutter (Dart SDK ^3.12.2), Drift 2.34 + sqlite3, `image` 4.9, Swift/AppKit + Vision (macOS), C++/WinRT + Windows.Media.Ocr (Windows).

**Spec:** `docs/superpowers/specs/2026-08-18-ocr-and-production-hardening-design.md`

## Global Constraints

- Dart SDK `^3.12.2`; Flutter lints from `flutter_lints ^6.0.0`. `flutter analyze` must report zero issues after every task.
- macOS deployment target is `12.0` (`macos/Podfile`, `MACOSX_DEPLOYMENT_TARGET`). Vision APIs must not require macOS 13+ without a runtime guard.
- Windows minimum is Windows 10. WinRT calls must degrade, not crash, when no OCR language pack is present.
- Drift: any schema change requires bumping `schemaVersion` and adding an `onUpgrade` branch (`GEMINI.md` §3.2). Run `dart run build_runner build --delete-conflicting-outputs` after editing table definitions.
- `ui.Image` instances must be `dispose()`d (`GEMINI.md` §2.1). Never store raw `ui.Image` in undo stacks.
- Annotation models stay pure data classes; no business logic in `CustomPainter.paint()` (`GEMINI.md` §1.1).
- Existing colour palette, gradients and annotation appearance are out of scope. This plan changes no visual design.
- Method channel name is exactly `snipsnap/ocr`.
- Commit after every task. Never commit with failing tests.

---

# Phase 1 — Coordinate Normalization

## Task 1: Record capture dimensions

Every `CaptureItem` is currently built with the default `width: 0, height: 0`, so
the DB has no image dimensions for any row. Task 3's migration needs them. This
task populates them going forward and backfills on load.

**Files:**
- Modify: `lib/models/capture_item.dart` (add `hasDimensions`)
- Modify: `lib/views/main_screen.dart:620-627` (`_addCaptureFromPath`)
- Modify: `lib/services/storage_service.dart:141-180` (`loadHistory`)
- Test: `test/capture_item_test.dart` (create)

**Interfaces:**
- Consumes: nothing
- Produces: `CaptureItem.hasDimensions` → `bool`; `CaptureItem.width`/`height` are non-zero for all captures created or loaded after this task.

- [ ] **Step 1: Write the failing test**

Create `test/capture_item_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/models/capture_item.dart';

void main() {
  test('hasDimensions is false when width or height is zero', () {
    final item = CaptureItem(
      id: 'a',
      filePath: '/tmp/a.png',
      title: 'A',
      createdAt: DateTime(2026, 1, 1),
    );
    expect(item.hasDimensions, isFalse);

    expect(item.copyWith(width: 100).hasDimensions, isFalse);
    expect(item.copyWith(width: 100, height: 50).hasDimensions, isTrue);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/capture_item_test.dart`
Expected: FAIL — `The getter 'hasDimensions' isn't defined for the class 'CaptureItem'`.

- [ ] **Step 3: Add the getter**

In `lib/models/capture_item.dart`, after the constructor:

```dart
  /// True when both dimensions were recorded. Captures created before
  /// dimensions were persisted report false and must be decoded to recover.
  bool get hasDimensions => width > 0 && height > 0;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/capture_item_test.dart`
Expected: PASS

- [ ] **Step 5: Populate dimensions when a capture is created**

In `lib/views/main_screen.dart`, change `_addCaptureFromPath` from `void` to
`Future<void>` and decode the image before constructing the item:

```dart
  Future<void> _addCaptureFromPath(String path) async {
    _syncCurrentCaptureAnnotations();

    int width = 0;
    int height = 0;
    try {
      final decoded = img.decodeImage(await File(path).readAsBytes());
      if (decoded != null) {
        width = decoded.width;
        height = decoded.height;
      }
    } catch (e) {
      debugPrint('SnipSnap dimension read error: $e');
    }

    final now = DateTime.now();
    final newItem = CaptureItem(
      id: '${now.millisecondsSinceEpoch}_${_captures.length}',
      filePath: path,
      title: 'Snap ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}',
      createdAt: now,
      width: width,
      height: height,
    );
```

Leave the rest of the method body unchanged. Update the four call sites that
invoke `_addCaptureFromPath(path)` to `await _addCaptureFromPath(path);` — they
are inside `_handleInteractiveCapture`, `_handleFullScreenCapture`,
`_handleTimerCapture` and `_handleImportImage`, all already `async`.

- [ ] **Step 6: Backfill dimensions for orphan files found on disk**

In `lib/services/storage_service.dart`, inside `loadHistory`'s directory scan,
replace the `newItem` construction so it records dimensions:

```dart
              final stat = await f.stat();
              int w = 0;
              int h = 0;
              try {
                final decoded = img.decodeImage(await f.readAsBytes());
                if (decoded != null) {
                  w = decoded.width;
                  h = decoded.height;
                }
              } catch (e) {
                debugPrint('SnipSnap dimension read error: $e');
              }
              final newItem = CaptureItem(
                id: '${stat.modified.millisecondsSinceEpoch}_${p.basename(f.path)}',
                filePath: f.path,
                title: 'Snap ${stat.modified.hour.toString().padLeft(2, '0')}:${stat.modified.minute.toString().padLeft(2, '0')}:${stat.modified.second.toString().padLeft(2, '0')}',
                createdAt: stat.modified,
                width: w,
                height: h,
              );
```

The id now includes the basename, which also removes the millisecond-collision
risk noted in the review.

- [ ] **Step 7: Verify the whole suite and analyzer**

Run: `flutter test && flutter analyze`
Expected: all tests pass, `No issues found!`

- [ ] **Step 8: Commit**

```bash
git add lib/models/capture_item.dart lib/views/main_screen.dart lib/services/storage_service.dart test/capture_item_test.dart
git commit -m "feat: record capture pixel dimensions on create and load"
```

---

## Task 2: `CanvasProjection` — the single coordinate conversion

The one piece of maths every later task depends on. Pure, no Flutter widgets,
fully unit tested.

**Files:**
- Create: `lib/utils/canvas_projection.dart`
- Test: `test/canvas_projection_test.dart` (create)

**Interfaces:**
- Consumes: `RenderService.imageRectInCanvas` (existing, `lib/services/render_service.dart:24`)
- Produces:
  - `CanvasProjection({required Size imageSize, required Size canvasSize})`
  - `bool get isValid`
  - `double get scale` — image pixels per canvas pixel
  - `Rect get imageRect`
  - `Offset toImage(Offset)` / `Offset toCanvas(Offset)`
  - `Rect toImageRect(Rect)` / `Rect toCanvasRect(Rect)`
  - `double toImageLength(double)` / `double toCanvasLength(double)`

- [ ] **Step 1: Write the failing test**

Create `test/canvas_projection_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/utils/canvas_projection.dart';

void main() {
  test('maps canvas points to image pixels through a letterboxed fit', () {
    // 1000x500 image inside an 800x800 canvas -> fits to 800x400, centred
    // vertically with 200px letterbox top and bottom. scale = 1000/800 = 1.25
    final p = CanvasProjection(
      imageSize: const Size(1000, 500),
      canvasSize: const Size(800, 800),
    );

    expect(p.isValid, isTrue);
    expect(p.scale, closeTo(1.25, 1e-9));
    expect(p.imageRect, const Rect.fromLTWH(0, 200, 800, 400));

    expect(p.toImage(const Offset(0, 200)), const Offset(0, 0));
    expect(p.toImage(const Offset(800, 600)), const Offset(1000, 500));
    expect(p.toImage(const Offset(400, 400)), const Offset(500, 250));
  });

  test('round-trips points at several viewport sizes', () {
    const imageSize = Size(1920, 1080);
    for (final canvas in const [
      Size(800, 600),
      Size(1440, 900),
      Size(300, 1200),
      Size(2000, 400),
    ]) {
      final p = CanvasProjection(imageSize: imageSize, canvasSize: canvas);
      for (final pt in const [Offset(0, 0), Offset(960, 540), Offset(1919, 1079)]) {
        final round = p.toImage(p.toCanvas(pt));
        expect(round.dx, closeTo(pt.dx, 1e-6), reason: 'canvas=$canvas pt=$pt');
        expect(round.dy, closeTo(pt.dy, 1e-6), reason: 'canvas=$canvas pt=$pt');
      }
    }
  });

  test('scales lengths so stroke weights survive the round trip', () {
    final p = CanvasProjection(
      imageSize: const Size(3840, 2160),
      canvasSize: const Size(960, 540),
    );
    expect(p.scale, closeTo(4.0, 1e-9));
    expect(p.toImageLength(3.0), closeTo(12.0, 1e-9));
    expect(p.toCanvasLength(12.0), closeTo(3.0, 1e-9));
  });

  test('is invalid for empty sizes and never divides by zero', () {
    expect(
      CanvasProjection(imageSize: Size.zero, canvasSize: const Size(10, 10)).isValid,
      isFalse,
    );
    expect(
      CanvasProjection(imageSize: const Size(10, 10), canvasSize: Size.zero).isValid,
      isFalse,
    );
    final invalid = CanvasProjection(imageSize: Size.zero, canvasSize: Size.zero);
    expect(invalid.scale, 1.0);
    expect(invalid.toImage(const Offset(5, 5)), const Offset(5, 5));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/canvas_projection_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:snipsnap/utils/canvas_projection.dart'`.

- [ ] **Step 3: Implement `CanvasProjection`**

Create `lib/utils/canvas_projection.dart`:

```dart
import 'package:flutter/painting.dart';

import '../services/render_service.dart';

/// Converts between canvas (viewport) coordinates and native image pixels.
///
/// Annotations are stored in image pixels so they stay attached to the pixels
/// they mark, independent of window size. Painting and hit-testing still work
/// in canvas coordinates, so this is the single boundary between the two.
///
/// Scalar dimensions (stroke width, font size, corner radius, blur sigma) are
/// scaled alongside points — a 3px stroke drawn on a downscaled 4K screenshot
/// is 12 image pixels, and storing it unscaled would change every stroke
/// weight on export.
@immutable
class CanvasProjection {
  final Size imageSize;
  final Size canvasSize;
  final Rect imageRect;

  CanvasProjection._(this.imageSize, this.canvasSize, this.imageRect);

  factory CanvasProjection({
    required Size imageSize,
    required Size canvasSize,
  }) {
    final rect = RenderService.imageRectInCanvas(
      imageSize: imageSize,
      canvasSize: canvasSize,
    );
    return CanvasProjection._(imageSize, canvasSize, rect);
  }

  /// False when either size is degenerate. Callers must not persist or export
  /// through an invalid projection — it cannot place anything correctly.
  bool get isValid =>
      !imageSize.isEmpty && !canvasSize.isEmpty && !imageRect.isEmpty;

  /// Image pixels per canvas pixel.
  double get scale => isValid ? imageSize.width / imageRect.width : 1.0;

  Offset toImage(Offset canvasPoint) {
    if (!isValid) return canvasPoint;
    return Offset(
      (canvasPoint.dx - imageRect.left) * scale,
      (canvasPoint.dy - imageRect.top) * scale,
    );
  }

  Offset toCanvas(Offset imagePoint) {
    if (!isValid) return imagePoint;
    return Offset(
      imageRect.left + imagePoint.dx / scale,
      imageRect.top + imagePoint.dy / scale,
    );
  }

  Rect toImageRect(Rect canvasRect) =>
      Rect.fromPoints(toImage(canvasRect.topLeft), toImage(canvasRect.bottomRight));

  Rect toCanvasRect(Rect imagePixelRect) =>
      Rect.fromPoints(toCanvas(imagePixelRect.topLeft), toCanvas(imagePixelRect.bottomRight));

  double toImageLength(double canvasLength) => canvasLength * scale;

  double toCanvasLength(double imageLength) => imageLength / scale;

  @override
  bool operator ==(Object other) =>
      other is CanvasProjection &&
      other.imageSize == imageSize &&
      other.canvasSize == canvasSize;

  @override
  int get hashCode => Object.hash(imageSize, canvasSize);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/canvas_projection_test.dart`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/utils/canvas_projection.dart test/canvas_projection_test.dart
git commit -m "feat: add CanvasProjection for canvas/image coordinate conversion"
```

---

## Task 3: Annotation space conversion

Adds the two methods that move a whole annotation between spaces, including
scalar dimensions.

**Files:**
- Modify: `lib/models/annotation.dart` (add `mappedToImageSpace`, `mappedToCanvasSpace`; extend `copyWith` sentinel)
- Test: `test/annotation_test.dart` (extend)

**Interfaces:**
- Consumes: `CanvasProjection` from Task 2
- Produces:
  - `Annotation.mappedToImageSpace(CanvasProjection)` → `Annotation`
  - `Annotation.mappedToCanvasSpace(CanvasProjection)` → `Annotation`
  - `copyWith` can now clear `startPoint`, `endPoint` and `rect` by passing `null` explicitly

- [ ] **Step 1: Write the failing test**

Append to `test/annotation_test.dart` inside `main()`:

```dart
  group('coordinate space mapping', () {
    final projection = CanvasProjection(
      imageSize: const Size(2000, 1000),
      canvasSize: const Size(1000, 1000),
    );

    test('round-trips geometry and scalar dimensions', () {
      final original = Annotation(
        id: 'x',
        tool: CanvasTool.arrow,
        color: const Color(0xFFFF0000),
        strokeWidth: 4.0,
        fontSize: 18.0,
        borderRadius: 8.0,
        blurStrength: 14.0,
        startPoint: const Offset(100, 300),
        endPoint: const Offset(400, 600),
        controlPoint: const Offset(250, 400),
        points: const [Offset(10, 260), Offset(20, 270)],
        rect: const Rect.fromLTRB(100, 300, 400, 600),
      );

      final round = original
          .mappedToImageSpace(projection)
          .mappedToCanvasSpace(projection);

      expect(round.startPoint!.dx, closeTo(100, 1e-6));
      expect(round.startPoint!.dy, closeTo(300, 1e-6));
      expect(round.endPoint!.dy, closeTo(600, 1e-6));
      expect(round.controlPoint!.dx, closeTo(250, 1e-6));
      expect(round.points.first.dx, closeTo(10, 1e-6));
      expect(round.rect!.right, closeTo(400, 1e-6));
      expect(round.strokeWidth, closeTo(4.0, 1e-6));
      expect(round.fontSize, closeTo(18.0, 1e-6));
      expect(round.borderRadius, closeTo(8.0, 1e-6));
      expect(round.blurStrength, closeTo(14.0, 1e-6));
    });

    test('scales stroke width into image pixels', () {
      final ann = Annotation(
        id: 'x',
        tool: CanvasTool.line,
        color: const Color(0xFF000000),
        strokeWidth: 3.0,
        startPoint: const Offset(0, 250),
        endPoint: const Offset(500, 250),
      );
      // 2000px image fitted into 1000px canvas -> scale 2.0
      final inImage = ann.mappedToImageSpace(projection);
      expect(inImage.strokeWidth, closeTo(6.0, 1e-6));
      expect(inImage.startPoint!.dx, closeTo(0, 1e-6));
      expect(inImage.endPoint!.dx, closeTo(1000, 1e-6));
    });

    test('copyWith can explicitly clear endPoint and rect', () {
      final ann = Annotation(
        id: 'x',
        tool: CanvasTool.text,
        color: const Color(0xFF000000),
        startPoint: const Offset(1, 2),
        endPoint: const Offset(3, 4),
        rect: const Rect.fromLTRB(0, 0, 5, 5),
      );
      final cleared = ann.copyWith(endPoint: null, rect: null);
      expect(cleared.endPoint, isNull);
      expect(cleared.rect, isNull);
      expect(cleared.startPoint, const Offset(1, 2));
    });
  });
```

Add these imports at the top of the file if not already present:

```dart
import 'package:snipsnap/utils/canvas_projection.dart';
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/annotation_test.dart`
Expected: FAIL — `The method 'mappedToImageSpace' isn't defined`.

- [ ] **Step 3: Extend the `copyWith` sentinel to geometry**

In `lib/models/annotation.dart`, change these three `copyWith` parameters from
typed nullables to sentinel-guarded `Object?`:

```dart
    Object? startPoint = _unset,
    Object? endPoint = _unset,
    Object? rect = _unset,
```

and their assignments in the returned constructor:

```dart
      startPoint: identical(startPoint, _unset) ? this.startPoint : startPoint as Offset?,
      endPoint: identical(endPoint, _unset) ? this.endPoint : endPoint as Offset?,
      rect: identical(rect, _unset) ? this.rect : rect as Rect?,
```

`translated()` already passes `null` for absent points, which under the sentinel
now means "clear". That is still correct because it only passes `null` where the
value was already `null`, but make the intent explicit:

```dart
  Annotation translated(Offset delta) {
    return copyWith(
      startPoint: startPoint == null ? null : startPoint! + delta,
      endPoint: endPoint == null ? null : endPoint! + delta,
      controlPoint: controlPoint == null ? null : controlPoint! + delta,
      points: points.map((p) => p + delta).toList(),
      rect: rect?.shift(delta),
    );
  }
```

- [ ] **Step 4: Add the two mapping methods**

In `lib/models/annotation.dart`, add the import:

```dart
import '../utils/canvas_projection.dart';
```

and these methods after `translated`:

```dart
  /// Converts every geometric and scalar dimension from canvas coordinates
  /// into native image pixels.
  Annotation mappedToImageSpace(CanvasProjection p) =>
      _mapped(p.toImage, p.toImageLength);

  /// Inverse of [mappedToImageSpace].
  Annotation mappedToCanvasSpace(CanvasProjection p) =>
      _mapped(p.toCanvas, p.toCanvasLength);

  Annotation _mapped(
    Offset Function(Offset) mapPoint,
    double Function(double) mapLength,
  ) {
    return copyWith(
      startPoint: startPoint == null ? null : mapPoint(startPoint!),
      endPoint: endPoint == null ? null : mapPoint(endPoint!),
      controlPoint: controlPoint == null ? null : mapPoint(controlPoint!),
      points: points.map(mapPoint).toList(),
      rect: rect == null
          ? null
          : Rect.fromPoints(mapPoint(rect!.topLeft), mapPoint(rect!.bottomRight)),
      strokeWidth: mapLength(strokeWidth),
      fontSize: mapLength(fontSize),
      borderRadius: mapLength(borderRadius),
      blurStrength: mapLength(blurStrength),
    );
  }
```

`blurStrength` is clamped to `1.0..60.0` by the constructor, so an extreme
downscale saturates rather than producing an invalid sigma. That is the desired
behaviour — a blur cannot be weaker than 1.

- [ ] **Step 5: Run tests to verify they pass**

Run: `flutter test test/annotation_test.dart`
Expected: PASS (all existing tests plus 3 new)

- [ ] **Step 6: Verify the two no-op call sites still behave**

`editor_canvas.dart:1204` and `:1272` call `.copyWith(endPoint: null)`. Under the
sentinel these now genuinely clear `endPoint`, which is what the code always
intended. Confirm nothing regressed:

Run: `flutter test && flutter analyze`
Expected: all pass, `No issues found!`

- [ ] **Step 7: Commit**

```bash
git add lib/models/annotation.dart test/annotation_test.dart
git commit -m "feat: add annotation image/canvas space mapping and clearable geometry"
```

---

## Task 4: Schema v4 — persist the coordinate space

**Files:**
- Modify: `lib/database/app_database.dart:23-52` (table), `:78-99` (version + migration)
- Modify: `lib/services/database_service.dart:120-215` (conversion helpers)
- Regenerate: `lib/database/app_database.g.dart`
- Test: `test/annotation_coord_space_test.dart` (create)

**Interfaces:**
- Consumes: `Annotation.mappedToImageSpace` / `mappedToCanvasSpace` (Task 3)
- Produces:
  - `Annotations.coordSpace` text column, default `'viewport'`
  - `DatabaseService.convertAnnotationFromDb(DbAnnotation)` returns an annotation tagged with its space via the new `AnnotationRow` record: `({Annotation annotation, CoordSpace space})`
  - `enum CoordSpace { viewport, imagePixels }` exported from `lib/utils/canvas_projection.dart`

- [ ] **Step 1: Add the `CoordSpace` enum**

Append to `lib/utils/canvas_projection.dart`:

```dart
/// Which coordinate system a persisted annotation's numbers are in.
///
/// Rows written before schema v4 are [viewport] — canvas coordinates whose
/// originating viewport was never recorded. They are converted once on load
/// and rewritten as [imagePixels].
enum CoordSpace { viewport, imagePixels }
```

- [ ] **Step 2: Write the failing test**

Create `test/annotation_coord_space_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/models/annotation.dart';
import 'package:snipsnap/utils/canvas_projection.dart';
import 'package:snipsnap/utils/constants.dart';

void main() {
  test('legacy viewport annotations convert once and stay stable after', () {
    final p = CanvasProjection(
      imageSize: const Size(1600, 900),
      canvasSize: const Size(800, 800),
    );

    final legacy = Annotation(
      id: 'legacy',
      tool: CanvasTool.shape,
      color: const Color(0xFF00FF00),
      strokeWidth: 2.0,
      startPoint: const Offset(100, 200),
      endPoint: const Offset(300, 400),
    );

    final converted = legacy.mappedToImageSpace(p);

    // Converting an already-converted annotation a second time must not be
    // applied twice — the caller is responsible for the space tag, so assert
    // the tag semantics rather than idempotency of the maths.
    expect(converted.startPoint, isNot(legacy.startPoint));
    expect(
      converted.mappedToCanvasSpace(p).startPoint!.dx,
      closeTo(100, 1e-6),
    );
  });

  test('CoordSpace parses by name with a viewport fallback', () {
    expect(coordSpaceByName('imagePixels'), CoordSpace.imagePixels);
    expect(coordSpaceByName('viewport'), CoordSpace.viewport);
    expect(coordSpaceByName(null), CoordSpace.viewport);
    expect(coordSpaceByName('nonsense'), CoordSpace.viewport);
  });
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `flutter test test/annotation_coord_space_test.dart`
Expected: FAIL — `The function 'coordSpaceByName' isn't defined`.

- [ ] **Step 4: Add the parser**

Append to `lib/utils/canvas_projection.dart`:

```dart
/// Parses a persisted [CoordSpace] name. Unknown and missing values fall back
/// to [CoordSpace.viewport] so pre-v4 rows are handled correctly by default.
CoordSpace coordSpaceByName(String? name) {
  for (final s in CoordSpace.values) {
    if (s.name == name) return s;
  }
  return CoordSpace.viewport;
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `flutter test test/annotation_coord_space_test.dart`
Expected: PASS (2 tests)

- [ ] **Step 6: Add the column and bump the schema**

In `lib/database/app_database.dart`, inside `class Annotations`:

```dart
  /// Which coordinate system [startX]/[startY]/[endX]/[endY]/[pointsJson] and
  /// the scalar dimensions are expressed in. Pre-v4 rows are 'viewport'.
  TextColumn get coordSpace => text().withDefault(const Constant('viewport'))();
```

Bump the version and add the migration branch:

```dart
  @override
  int get schemaVersion => 4;
```

```dart
        if (from < 4) {
          await m.addColumn(annotations, annotations.coordSpace);
        }
```

- [ ] **Step 7: Regenerate Drift code**

Run: `dart run build_runner build --delete-conflicting-outputs`
Expected: `lib/database/app_database.g.dart` regenerates with the new column, build succeeds.

- [ ] **Step 8: Persist and read the space**

In `lib/services/database_service.dart`, add the import:

```dart
import '../utils/canvas_projection.dart';
```

Change `_convertAnnotationFromDb` to return the space alongside the annotation.
Rename it and change its signature:

```dart
  /// An annotation as stored, together with the coordinate space its numbers
  /// are in. Callers must convert [CoordSpace.viewport] rows before use.
  static ({Annotation annotation, CoordSpace space}) convertAnnotationFromDb(
    DbAnnotation a,
  ) {
```

Change its final `return annotation;` to:

```dart
    return (annotation: annotation, space: coordSpaceByName(a.coordSpace));
```

In `loadCapturesFromDb`, replace the mapping line:

```dart
      final annotations = annRows.map((a) => convertAnnotationFromDb(a)).toList();
```

with a form that keeps the space available to the caller. Add a top-level
record type to the same file:

```dart
  /// Annotations for one capture, paired with the space they were stored in.
  static ({List<Annotation> annotations, bool needsConversion})
      _annotationsFor(List<DbAnnotation> rows) {
    final converted = rows.map(convertAnnotationFromDb).toList();
    return (
      annotations: converted.map((r) => r.annotation).toList(),
      needsConversion: converted.any((r) => r.space == CoordSpace.viewport),
    );
  }
```

and use it:

```dart
      final annRows = await db.getAnnotationsForCapture(row.id);
      final parsed = _annotationsFor(annRows);

      items.add(CaptureItem(
        id: row.id,
        filePath: row.filePath,
        title: row.title,
        createdAt: row.createdAt,
        width: row.width,
        height: row.height,
        annotations: parsed.annotations,
        annotationsNeedConversion: parsed.needsConversion,
      ));
```

Add the matching field to `CaptureItem` in `lib/models/capture_item.dart`
(constructor parameter, field, and `copyWith` passthrough):

```dart
  /// True when this capture's annotations were loaded from pre-v4 rows and
  /// still hold viewport coordinates. Cleared once converted.
  final bool annotationsNeedConversion;
```

defaulting to `false`, and include it in `copyWith` as
`annotationsNeedConversion: annotationsNeedConversion ?? this.annotationsNeedConversion`.

In `_convertAnnotationToCompanion`, always write the new space:

```dart
      coordSpace: Value(CoordSpace.imagePixels.name),
```

- [ ] **Step 9: Verify**

Run: `flutter test && flutter analyze`
Expected: all pass, `No issues found!`

- [ ] **Step 10: Commit**

```bash
git add lib/database/ lib/services/database_service.dart lib/models/capture_item.dart lib/utils/canvas_projection.dart test/annotation_coord_space_test.dart
git commit -m "feat: persist annotation coordinate space, schema v4"
```

---

## Task 5: Convert legacy annotations on load

**Files:**
- Modify: `lib/views/main_screen.dart` (`_loadHistory`, `_selectCapture` path)
- Test: `test/legacy_conversion_test.dart` (create)

**Interfaces:**
- Consumes: `CaptureItem.annotationsNeedConversion` (Task 4), `CanvasProjection` (Task 2)
- Produces: `_MainScreenState._convertLegacyAnnotations(CaptureItem, Size canvasSize)` → `List<Annotation>`

- [ ] **Step 1: Write the failing test**

Create `test/legacy_conversion_test.dart`. The conversion logic must be a pure
top-level function so it is testable without a widget tree — put it in
`lib/utils/canvas_projection.dart` rather than in the State class:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/models/annotation.dart';
import 'package:snipsnap/utils/canvas_projection.dart';
import 'package:snipsnap/utils/constants.dart';

void main() {
  Annotation ann(Offset start) => Annotation(
        id: 's',
        tool: CanvasTool.line,
        color: const Color(0xFF000000),
        strokeWidth: 2.0,
        startPoint: start,
        endPoint: start + const Offset(50, 50),
      );

  test('converts viewport annotations into image pixels', () {
    final result = convertLegacyAnnotations(
      annotations: [ann(const Offset(100, 100))],
      imageSize: const Size(2000, 2000),
      canvasSize: const Size(1000, 1000),
    );
    expect(result.single.startPoint!.dx, closeTo(200, 1e-6));
    expect(result.single.strokeWidth, closeTo(4.0, 1e-6));
  });

  test('returns annotations untouched when the projection is invalid', () {
    final input = [ann(const Offset(100, 100))];
    final result = convertLegacyAnnotations(
      annotations: input,
      imageSize: Size.zero,
      canvasSize: const Size(1000, 1000),
    );
    expect(result.single.startPoint, const Offset(100, 100));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/legacy_conversion_test.dart`
Expected: FAIL — `The function 'convertLegacyAnnotations' isn't defined`.

- [ ] **Step 3: Implement the conversion**

Append to `lib/utils/canvas_projection.dart`:

```dart
/// Converts pre-v4 annotations from viewport coordinates into image pixels.
///
/// The viewport that produced these numbers was never recorded, so the current
/// canvas is used as the best available estimate. This is exact when the window
/// is the size it was at draw time and approximate otherwise — the same
/// accuracy the rows already had, with the drift frozen instead of recurring on
/// every later resize.
///
/// Returns the input unchanged when the projection is invalid, so a conversion
/// can never scramble coordinates using a degenerate transform.
List<Annotation> convertLegacyAnnotations({
  required List<Annotation> annotations,
  required Size imageSize,
  required Size canvasSize,
}) {
  final projection =
      CanvasProjection(imageSize: imageSize, canvasSize: canvasSize);
  if (!projection.isValid) return annotations;
  return annotations.map((a) => a.mappedToImageSpace(projection)).toList();
}
```

Add `import '../models/annotation.dart';` to the file's imports.

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/legacy_conversion_test.dart`
Expected: PASS (2 tests)

- [ ] **Step 5: Call it from `_loadHistory`**

In `lib/views/main_screen.dart`, after the active capture is chosen in
`_loadHistory`, convert and persist once. Because conversion needs a laid-out
canvas, run it in a post-frame callback:

```dart
      if (_activeCapture != null && _activeCapture!.annotationsNeedConversion) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _convertActiveCaptureAnnotations();
        });
      }
```

and add the method:

```dart
  /// One-time migration of a pre-v4 capture's annotations into image pixels.
  Future<void> _convertActiveCaptureAnnotations() async {
    var capture = _activeCapture;
    if (capture == null || !capture.annotationsNeedConversion) return;

    // Captures written before Task 1 have no recorded dimensions, which is the
    // common case for existing installs. Decode once to recover them.
    if (!capture.hasDimensions) {
      try {
        final decoded = img.decodeImage(await File(capture.filePath).readAsBytes());
        if (decoded == null) return;
        capture = capture.copyWith(width: decoded.width, height: decoded.height);
      } catch (e) {
        debugPrint('SnipSnap legacy dimension read error: $e');
        return;
      }
      if (!mounted) return;
    }

    final imageSize = Size(capture.width.toDouble(), capture.height.toDouble());
    final converted = convertLegacyAnnotations(
      annotations: _annotations,
      imageSize: imageSize,
      canvasSize: _canvasSize,
    );

    final resolved = capture;
    setState(() {
      _annotations = converted;
      _activeCapture =
          resolved.copyWith(annotationsNeedConversion: false, annotations: converted);
    });
    // Rewrites the rows with coordSpace = imagePixels so this never runs again.
    _syncCurrentCaptureAnnotations();
  }
```

Add the import `import '../utils/canvas_projection.dart';`.

- [ ] **Step 6: Verify**

Run: `flutter test && flutter analyze`
Expected: all pass, `No issues found!`

- [ ] **Step 7: Commit**

```bash
git add lib/utils/canvas_projection.dart lib/views/main_screen.dart test/legacy_conversion_test.dart
git commit -m "feat: convert pre-v4 viewport annotations to image pixels on load"
```

---

## Task 6: `EditorCanvas` converts at the gesture and paint boundary

The in-memory list becomes image-pixel space. `AnnotationRenderer` and every
hit-test keep working in canvas space and are not modified.

**Files:**
- Modify: `lib/views/editor_canvas.dart` — `_canvasSize` (`:344`), `_imageRect` (`:350`), gesture handlers (`:750`, `:890`, `:1048`, `:1142`), `_AnnotationPainter` (`:2586`)
- Test: `test/editor_canvas_projection_test.dart` (create)

**Interfaces:**
- Consumes: `CanvasProjection` (Task 2), `Annotation.mappedTo*Space` (Task 3)
- Produces: `_EditorCanvasState._projection` → `CanvasProjection`; `_toImage(Offset)` / `_canvasAnnotations` helpers

- [ ] **Step 1: Add the projection getter and the canvas-space view**

In `lib/views/editor_canvas.dart`, add the import:

```dart
import '../utils/canvas_projection.dart';
```

and inside `_EditorCanvasState`, next to `_imageRect`:

```dart
  CanvasProjection get _projection {
    final image = _baseImage;
    return CanvasProjection(
      imageSize: image == null
          ? Size.zero
          : Size(image.width.toDouble(), image.height.toDouble()),
      canvasSize: _canvasSize,
    );
  }

  /// `widget.annotations` are stored in image pixels; painting and hit-testing
  /// work in canvas coordinates. Memoised because it runs every build.
  List<Annotation> get _canvasAnnotations {
    final p = _projection;
    if (_canvasAnnotationsCache != null &&
        _cachedProjection == p &&
        identical(_cachedSource, widget.annotations)) {
      return _canvasAnnotationsCache!;
    }
    final mapped = p.isValid
        ? widget.annotations.map((a) => a.mappedToCanvasSpace(p)).toList()
        : widget.annotations;
    _canvasAnnotationsCache = mapped;
    _cachedProjection = p;
    _cachedSource = widget.annotations;
    return mapped;
  }

  List<Annotation>? _canvasAnnotationsCache;
  CanvasProjection? _cachedProjection;
  List<Annotation>? _cachedSource;

  Offset _toImage(Offset canvasPoint) => _projection.toImage(canvasPoint);
```

- [ ] **Step 2: Route every read of `widget.annotations` through `_canvasAnnotations`**

Replace `widget.annotations` with `_canvasAnnotations` in these methods, which
all operate in canvas space: `_selectedAnnotation` (`:411`), `_hitTestAnnotation`
(`:434`), `_replaceAnnotation`'s `indexWhere` lookup (`:474`), and the
`_AnnotationPainter` construction in `build` (`:1876`).

`_replaceAnnotation` must convert back before calling out, because the parent
stores image pixels. Change its body to:

```dart
  void _replaceAnnotation(Annotation updated, {required bool live}) {
    final callback =
        live ? (widget.onAnnotationsLiveUpdated ?? widget.onAnnotationsUpdated) : widget.onAnnotationsUpdated;
    if (callback == null) return;
    final index = widget.annotations.indexWhere((a) => a.id == updated.id);
    if (index == -1) return;
    final p = _projection;
    final list = List<Annotation>.from(widget.annotations);
    list[index] = p.isValid ? updated.mappedToImageSpace(p) : updated;
    callback(list);
  }
```

- [ ] **Step 3: Convert on annotation creation**

Every place that calls `widget.onAnnotationAdded(...)` passes a canvas-space
annotation. Add one private method and route all of them through it:

```dart
  void _emitAnnotation(Annotation canvasSpaceAnnotation) {
    final p = _projection;
    widget.onAnnotationAdded(
      p.isValid ? canvasSpaceAnnotation.mappedToImageSpace(p) : canvasSpaceAnnotation,
    );
  }
```

Replace the three `widget.onAnnotationAdded(annotation)` call sites — in
`_onPanEnd` (`:1048`), `_onTapUp`'s `stepMarker` branch (`:1205`), and
`_commitInlineText` (`:1273`) — with `_emitAnnotation(annotation)`.

Do the same for `_pushHistoryCheckpoint` (`:487`) and the
`widget.onAnnotationsUpdated?.call(...)` in `_commitInlineText`'s empty-text
branch: both pass `widget.annotations` straight through, which is already image
space, so they need no change. Confirm by reading each before editing.

- [ ] **Step 4: Write the regression test**

Create `test/editor_canvas_projection_test.dart`:

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:snipsnap/models/annotation.dart';
import 'package:snipsnap/utils/canvas_projection.dart';
import 'package:snipsnap/utils/constants.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an annotation keeps its image position across viewport sizes', () {
    // Stored in image pixels: a line across the middle of a 1600x900 image.
    final stored = Annotation(
      id: 'a',
      tool: CanvasTool.line,
      color: const Color(0xFF000000),
      strokeWidth: 8.0,
      startPoint: const Offset(800, 450),
      endPoint: const Offset(1200, 450),
    );

    const imageSize = Size(1600, 900);
    Offset canvasStartFor(Size canvas) {
      final p = CanvasProjection(imageSize: imageSize, canvasSize: canvas);
      return p.toImage(stored.mappedToCanvasSpace(p).startPoint!);
    }

    // Whatever the window size, converting to canvas and back lands on the
    // same image pixel. This is the drift regression.
    for (final canvas in const [
      Size(800, 600),
      Size(1600, 900),
      Size(400, 1000),
    ]) {
      final round = canvasStartFor(canvas);
      expect(round.dx, closeTo(800, 1e-6), reason: 'canvas=$canvas');
      expect(round.dy, closeTo(450, 1e-6), reason: 'canvas=$canvas');
    }
  });
}
```

- [ ] **Step 5: Run the test**

Run: `flutter test test/editor_canvas_projection_test.dart`
Expected: PASS

- [ ] **Step 6: Verify the full suite**

Run: `flutter test && flutter analyze`
Expected: all pass, `No issues found!`

- [ ] **Step 7: Manual smoke test**

Run: `flutter run -d macos`

Verify by hand, because no widget test covers the live canvas:
1. Import an image, draw an arrow over a specific feature.
2. Resize the window substantially. **The arrow must stay on that feature.**
3. Quit and relaunch at a different window size. The arrow must still be there.
4. Export and confirm the arrow lands in the same place in the PNG.

- [ ] **Step 8: Commit**

```bash
git add lib/views/editor_canvas.dart test/editor_canvas_projection_test.dart
git commit -m "feat: store annotations in image pixels, convert at canvas boundary"
```

---

## Task 7: Export, crop and ruler correctness

**Files:**
- Modify: `lib/views/main_screen.dart:641` (`_canvasSize`), `:648` (`_renderAnnotatedBytes`), `:783` (`_handleApplyCrop`)
- Modify: `lib/services/render_service.dart:60-150` (`renderFlattenedPng`)
- Modify: `lib/views/components/annotation_renderer.dart:719-756` (`_drawRuler`)
- Test: `test/render_service_test.dart` (extend)

**Interfaces:**
- Consumes: `CanvasProjection` (Task 2)
- Produces: `RenderService.renderFlattenedPng` now takes `annotationsAreImageSpace: true` and throws `StateError` on an invalid projection rather than silently dropping annotations.

- [ ] **Step 1: Write the failing test**

Append to `test/render_service_test.dart` inside `main()`:

```dart
  test('throws rather than silently dropping annotations on a zero canvas', () async {
    final path = await _writeWhitePng(tempDir, 200, 100);
    final annotations = [
      Annotation(
        id: 'a',
        tool: CanvasTool.shape,
        color: const Color(0xFFFF0000),
        strokeWidth: 4.0,
        startPoint: const Offset(10, 10),
        endPoint: const Offset(90, 60),
      ),
    ];

    expect(
      () => RenderService.renderFlattenedPng(
        imagePath: path,
        annotations: annotations,
        canvasSize: Size.zero,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('still returns original bytes when there is nothing to composite', () async {
    final path = await _writeWhitePng(tempDir, 200, 100);
    final bytes = await RenderService.renderFlattenedPng(
      imagePath: path,
      annotations: const [],
      canvasSize: Size.zero,
    );
    expect(bytes, isNotNull);
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/render_service_test.dart`
Expected: FAIL — the first test returns bytes instead of throwing.

- [ ] **Step 3: Make the invalid-projection path loud**

In `lib/services/render_service.dart`, replace the two silent fallbacks. After
computing `imageRect`:

```dart
      final imageRect = imageRectInCanvas(imageSize: imageSize, canvasSize: canvasSize);

      // An empty rect means the editor canvas was never laid out. Rendering
      // through it would place nothing correctly, so fail loudly instead of
      // returning a file that looks saved but has lost its markup.
      if (imageRect.isEmpty && annotations.isNotEmpty) {
        throw StateError(
          'Cannot flatten ${annotations.length} annotation(s): the editor canvas '
          'has no size (canvasSize=$canvasSize). The capture was not exported.',
        );
      }
      if (imageRect.isEmpty && !hasFraming) {
        return await File(imagePath).readAsBytes();
      }
```

Delete the now-unreachable `imageRect.isEmpty ? 1.0 :` guard on `scale` and use
`imageSize.width / imageRect.width` directly, and drop the
`if (!imageRect.isEmpty)` wrapper around the `AnnotationRenderer.paintAll` block
— both are guaranteed non-empty past the check when there are annotations. Keep
the framing-only path working by leaving the block guarded on
`annotations.isNotEmpty` instead.

- [ ] **Step 4: Surface the error in the UI**

In `lib/views/main_screen.dart`, wrap `_renderAnnotatedBytes`'s call:

```dart
  Future<Uint8List?> _renderAnnotatedBytes() async {
    final capture = _activeCapture;
    if (capture == null) return null;

    try {
      final bytes = await RenderService.renderFlattenedPng(
        imagePath: capture.filePath,
        annotations: _annotations,
        canvasSize: _canvasSize,
      );
      if (bytes != null) return bytes;
    } on StateError catch (e) {
      debugPrint('SnipSnap export error: $e');
      _showToast('Could not export: the editor is not ready. Try again.');
      return null;
    }

    if (File(capture.filePath).existsSync()) {
      return await File(capture.filePath).readAsBytes();
    }
    return null;
  }
```

Make `_canvasSize` in `main_screen.dart` consistent with the editor's by
returning `Size.zero` in both, and remove the `Size(800, 600)` fallback in
`editor_canvas.dart:347`:

```dart
  Size get _canvasSize {
    final renderObj = widget.repaintBoundaryKey.currentContext?.findRenderObject();
    if (renderObj is RenderBox && renderObj.hasSize) return renderObj.size;
    return Size.zero;
  }
```

- [ ] **Step 5: Make the crop failure loud too**

In `_handleApplyCrop`, replace `if (imageRect.isEmpty) return;` with:

```dart
      if (imageRect.isEmpty) {
        _showToast('Could not crop: the editor is not ready. Try again.');
        return;
      }
```

- [ ] **Step 6: Fix the ruler measurement**

`_drawRuler` receives canvas-space annotations, so its length is display pixels.
Pass the scale through so the badge reports image pixels. In
`lib/views/components/annotation_renderer.dart`, add an optional parameter to
`paint` and `paintAll`:

```dart
  static void paintAll(
    Canvas canvas,
    List<Annotation> annotations, {
    ui.Image? baseImage,
    Rect? imageRect,
    double pixelScale = 1.0,
  }) {
```

Thread `pixelScale` through to `_drawRuler` and use it in the badge only:

```dart
    _drawBadge(
      canvas,
      center: Offset((start.dx + end.dx) / 2, (start.dy + end.dy) / 2) - normal * (capHalf + 12),
      text: '${(length * pixelScale).round()} px',
      background: _applyOpacity(ann.color, ann.opacity),
    );
```

The geometry, ticks and caps stay in canvas units — only the reported number
changes. Pass `pixelScale: _projection.scale` from `_AnnotationPainter` and
`pixelScale: scale` from `RenderService`.

- [ ] **Step 7: Test the ruler**

Append to `test/annotation_test.dart`:

```dart
  test('ruler reports image pixels, not display pixels', () {
    final p = CanvasProjection(
      imageSize: const Size(3840, 2160),
      canvasSize: const Size(960, 540),
    );
    // A ruler spanning 100 canvas px across a 4x-downscaled image measures
    // 400 image px.
    expect((100 * p.scale).round(), 400);
  });
```

- [ ] **Step 8: Verify**

Run: `flutter test && flutter analyze`
Expected: all pass, `No issues found!`

- [ ] **Step 9: Commit**

```bash
git add lib/services/render_service.dart lib/views/main_screen.dart lib/views/editor_canvas.dart lib/views/components/annotation_renderer.dart test/
git commit -m "fix: fail loudly on invalid canvas, report ruler length in image pixels"
```

---

# Phase 2 — Tool Layer Consolidation

## Task 8: Fix the incorrect snap assertion

**Files:**
- Modify: `test/tool_handlers_test.dart:186-196`

**Interfaces:**
- Consumes: nothing
- Produces: a green suite, which every later task depends on to detect regressions

- [ ] **Step 1: Confirm the current failure**

Run: `flutter test test/tool_handlers_test.dart`
Expected: FAIL — `Expected: a numeric value within <0.0001> of <0.0> / Actual: <26.171456267316447>`

- [ ] **Step 2: Correct the test**

A drag to `(100, 15)` is 8.53°, which correctly snaps to 15° because the
boundary for 15° increments is 7.5°. Use a drag that is genuinely below the
boundary:

```dart
    test('shift-snaps line to 15-degree angles', () {
      final delegate = MockToolDelegate()..isShiftDown = true;
      final handler = LineToolHandler(delegate);

      handler.onPanStart(_dragStart(const Offset(0, 0)), const Offset(0, 0));
      // 2.9 degrees — below the 7.5 degree boundary, so it snaps to horizontal.
      handler.onPanUpdate(_dragUpdate(const Offset(100, 5)), const Offset(100, 5));
      final end = delegate.currentAnnotation!.endPoint!;
      expect(end.dy, closeTo(0.0, 1e-4));
      expect(end.dx, greaterThan(95));
    });

    test('shift-snaps a 10-degree drag up to the 15-degree increment', () {
      final delegate = MockToolDelegate()..isShiftDown = true;
      final handler = LineToolHandler(delegate);

      handler.onPanStart(_dragStart(const Offset(0, 0)), const Offset(0, 0));
      handler.onPanUpdate(_dragUpdate(const Offset(100, 18)), const Offset(100, 18));
      final end = delegate.currentAnnotation!.endPoint!;
      // 10.2 degrees rounds to 15, so dy = |end| * sin(15deg) > 0.
      expect(end.dy, greaterThan(20));
    });
```

- [ ] **Step 3: Run test to verify it passes**

Run: `flutter test test/tool_handlers_test.dart`
Expected: PASS (17 tests)

- [ ] **Step 4: Commit**

```bash
git add test/tool_handlers_test.dart
git commit -m "test: correct the 15-degree snap assertion"
```

---

## Task 9: Wire `ToolHandler` into `EditorCanvas`

`lib/tools/` is currently unreachable — nothing outside it imports it, and
`EditorCanvas` duplicates every handler inline. This task makes the handlers the
single implementation, which is what `GEMINI.md` §1.1 already requires.

**Files:**
- Modify: `lib/tools/tool_handler.dart` (add `ToolHandlerFactory`)
- Modify: `lib/views/editor_canvas.dart` — `_onPanStart` (`:750`), `_onPanUpdate` (`:890`), `_onPanEnd` (`:1048`), `_onTapUp` (`:1142`)
- Modify: `lib/tools/crop_tool.dart:46` (remove the hardcoded fallback)
- Test: `test/tool_handlers_test.dart` (extend)

**Interfaces:**
- Consumes: every handler in `lib/tools/`
- Produces: `ToolHandler handlerFor(CanvasTool tool, ToolDelegate delegate)` in `lib/tools/tool_handler.dart`

- [ ] **Step 1: Diff the two implementations before touching anything**

The inline and handler versions have drifted. Read both and note every
difference, because this task must not silently change gesture behaviour:

Run: `sed -n '399,433p;726,760p' lib/views/editor_canvas.dart`
Run: `cat lib/tools/highlighter_tool.dart lib/tools/blur_tool.dart`

Known differences to reconcile, keeping the **canvas** behaviour as the
reference since it is what ships today:
- `HighlighterToolHandler` shift-locks to horizontal/vertical; the canvas routes
  highlight through the generic freehand path.
- `BlurToolHandler` and `_constrainEndPoint` differ in the negative-delta case.
- `CropToolHandler` resets to a hardcoded `Rect.fromLTWH(0, 0, 800, 600)`.

- [ ] **Step 2: Write the failing test for the factory**

Append to `test/tool_handlers_test.dart`:

```dart
  group('handlerFor', () {
    test('returns a distinct handler for every CanvasTool', () {
      final delegate = MockToolDelegate();
      for (final tool in CanvasTool.values) {
        expect(
          () => handlerFor(tool, delegate),
          returnsNormally,
          reason: 'no handler for $tool',
        );
      }
    });

    test('maps each tool to its matching handler type', () {
      final d = MockToolDelegate();
      expect(handlerFor(CanvasTool.arrow, d), isA<ArrowToolHandler>());
      expect(handlerFor(CanvasTool.line, d), isA<LineToolHandler>());
      expect(handlerFor(CanvasTool.shape, d), isA<ShapeToolHandler>());
      expect(handlerFor(CanvasTool.pen, d), isA<PenToolHandler>());
      expect(handlerFor(CanvasTool.highlight, d), isA<HighlighterToolHandler>());
      expect(handlerFor(CanvasTool.blur, d), isA<BlurToolHandler>());
      expect(handlerFor(CanvasTool.ruler, d), isA<RulerToolHandler>());
      expect(handlerFor(CanvasTool.stepMarker, d), isA<StepMarkerToolHandler>());
      expect(handlerFor(CanvasTool.text, d), isA<TextToolHandler>());
      expect(handlerFor(CanvasTool.fill, d), isA<FillToolHandler>());
      expect(handlerFor(CanvasTool.colorPicker, d), isA<ColorPickerToolHandler>());
      expect(handlerFor(CanvasTool.crop, d), isA<CropToolHandler>());
      expect(handlerFor(CanvasTool.select, d), isA<SelectToolHandler>());
    });
  });
```

- [ ] **Step 3: Run test to verify it fails**

Run: `flutter test test/tool_handlers_test.dart`
Expected: FAIL — `The function 'handlerFor' isn't defined`.

- [ ] **Step 4: Implement the factory**

Append to `lib/tools/tool_handler.dart`, with the imports for every handler:

```dart
/// The handler that owns gestures for [tool].
///
/// `EditorCanvas` delegates to these rather than implementing gestures inline,
/// so tool behaviour lives in one place (GEMINI.md 1.1).
ToolHandler handlerFor(CanvasTool tool, ToolDelegate delegate) {
  switch (tool) {
    case CanvasTool.select:
      return SelectToolHandler(delegate);
    case CanvasTool.pen:
      return PenToolHandler(delegate);
    case CanvasTool.arrow:
      return ArrowToolHandler(delegate);
    case CanvasTool.line:
      return LineToolHandler(delegate);
    case CanvasTool.shape:
      return ShapeToolHandler(delegate);
    case CanvasTool.highlight:
      return HighlighterToolHandler(delegate);
    case CanvasTool.stepMarker:
      return StepMarkerToolHandler(delegate);
    case CanvasTool.text:
      return TextToolHandler(delegate);
    case CanvasTool.blur:
      return BlurToolHandler(delegate);
    case CanvasTool.ruler:
      return RulerToolHandler(delegate);
    case CanvasTool.crop:
      return CropToolHandler(delegate);
    case CanvasTool.fill:
      return FillToolHandler(delegate);
    case CanvasTool.colorPicker:
      return ColorPickerToolHandler(delegate);
  }
}
```

- [ ] **Step 5: Remove the hardcoded crop fallback**

In `lib/tools/crop_tool.dart`, replace the `else` branch in `onPanEnd`:

```dart
      } else {
        // Too small to be a deliberate crop — discard it and leave the
        // existing rect alone rather than inventing an 800x600 default.
        delegate.onActiveCropRectChanged(null);
        delegate.onCurrentAnnotationChanged(null);
      }
```

- [ ] **Step 6: Make `_EditorCanvasState` implement `ToolDelegate`**

Change the class declaration:

```dart
class _EditorCanvasState extends State<EditorCanvas> implements ToolDelegate {
```

Implement the delegate getters against existing widget properties.

Rename `_hitTestAnnotation` (`:434`) to `hitTestAnnotation` and mark it
`@override` — the interface declares it public. Update its four call sites in
`_onPanStart` and `_onTapUp`:

Run: `grep -n "_hitTestAnnotation" lib/views/editor_canvas.dart`
Rename every hit. Do not rename `_hitTestAnnotationHandles` or
`_hitTestCropRect`, which stay private to the canvas.

Then add:

```dart
  @override
  List<Annotation> get annotations => _canvasAnnotations;
  @override
  String? get selectedAnnotationId => _selectedAnnotationId;
  @override
  Annotation? get currentAnnotation => _currentAnnotation;
  @override
  Rect? get activeCropRect => _activeCropRect;
  @override
  Color get activeColor => widget.activeColor;
  @override
  double get strokeWidth => widget.strokeWidth;
  @override
  double get opacity => widget.opacity;
  @override
  double get fontSize => widget.fontSize;
  @override
  bool get isFilled => widget.isFilled;
  @override
  Color? get textBackgroundColor => widget.textBackgroundColor;
  @override
  Color? get fillColor => widget.fillColor;
  @override
  int get stepCounter => widget.stepCounter;
  @override
  double get blurStrength => widget.blurStrength;
  @override
  double get borderRadius => widget.borderRadius;
  @override
  ShapeKind get shapeKind => widget.shapeKind;
  @override
  LineStyle get lineStyle => widget.lineStyle;
  @override
  BlurType get blurType => widget.blurType;
  @override
  bool get isDoubleArrow => widget.isDoubleArrow;
  @override
  bool get hasShadow => widget.hasShadow;
  @override
  double get fillTolerance => widget.fillTolerance;
  @override
  bool get isGlobalFill => widget.isGlobalFill;
  @override
  bool get isShiftDown => _isShiftDown;
  @override
  bool get isAltDown => _isAltDown;

  @override
  void onAnnotationAdded(Annotation annotation) => _emitAnnotation(annotation);
  @override
  void onActiveCropRectChanged(Rect? rect) => setState(() => _activeCropRect = rect);
  @override
  void onCurrentAnnotationChanged(Annotation? annotation) =>
      setState(() => _currentAnnotation = annotation);
  @override
  void onSelectedAnnotationIdChanged(String? id) =>
      setState(() => _selectedAnnotationId = id);
  @override
  void onToolSelected(CanvasTool tool) => widget.onToolSelected?.call(tool);
  @override
  void onStepCounterIncremented(int step) => widget.onStepCounterIncremented(step);
  @override
  void showTextPrompt(Offset pos) => _startInlineTextEdit(pos);
  @override
  void updateAnnotation(String id, Annotation updated) =>
      _replaceAnnotation(updated, live: true);
  // Handlers pass canvas-space lists, and the parent stores image pixels, so
  // this converts before handing off. No handler calls it today, but the
  // interface declares it and an unconverted implementation would be a
  // latent coordinate bug.
  @override
  void pushAnnotationsState(List<Annotation> newAnnotations) {
    final p = _projection;
    widget.onAnnotationsUpdated?.call(
      p.isValid
          ? newAnnotations.map((a) => a.mappedToImageSpace(p)).toList()
          : newAnnotations,
    );
  }
  @override
  void onPerformCanvasFill(Offset pos) => _performCanvasFloodFill(pos);
  @override
  void onSampleColorFromCanvas(Offset pos) => _sampleColorAt(pos);
```

- [ ] **Step 7: Delegate the four gesture entry points**

Keep the canvas-owned behaviour (crop-handle dragging, floating selection,
annotation transform handles, marquee) at the top of each handler. Once none of
those claim the gesture, hand off:

```dart
  ToolHandler get _toolHandler {
    if (_cachedHandlerTool != widget.activeTool) {
      _cachedHandler = handlerFor(widget.activeTool, this);
      _cachedHandlerTool = widget.activeTool;
    }
    return _cachedHandler!;
  }

  ToolHandler? _cachedHandler;
  CanvasTool? _cachedHandlerTool;
```

At the end of `_onPanStart`, replace the inline
`setState(() { _currentAnnotation = _buildAnnotationForTool(...); })` block with:

```dart
    _drawStart = pos;
    _toolHandler.onPanStart(details, pos);
```

In `_onPanUpdate`, replace the tool-specific branch (the section that rebuilds
`_currentAnnotation` from `_constrainEndPoint` and `_currentPoints`) with:

```dart
    _toolHandler.onPanUpdate(details, pos);
```

In `_onPanEnd`, replace the annotation-commit branch with:

```dart
    _toolHandler.onPanEnd(details);
```

In `_onTapUp`, replace the `fill`, `colorPicker`, `stepMarker` and `text`
branches with:

```dart
    _toolHandler.onTapUp(details, pos);
```

Delete `_buildAnnotationForTool` and `_constrainEndPoint` — the handlers own
both now.

- [ ] **Step 8: Run the full suite**

Run: `flutter test && flutter analyze`
Expected: all pass, `No issues found!`

- [ ] **Step 9: Manual gesture regression pass**

Run: `flutter run -d macos`

Exercise every tool and confirm behaviour is unchanged from before the task:
arrow (plus shift-snap and alt-centre), line, all 8 shape kinds, pen,
highlighter (plus shift), step marker, text, blur, ruler, fill, eyedropper,
crop. Any behaviour change is a bug in this task, not an improvement.

- [ ] **Step 10: Commit**

```bash
git add lib/tools/ lib/views/editor_canvas.dart test/tool_handlers_test.dart
git commit -m "refactor: route canvas gestures through the ToolHandler strategies"
```

---

# Phase 3 — OCR

## Task 10: `OcrEngine` interface and result model

**Files:**
- Create: `lib/services/ocr/ocr_engine.dart`
- Create: `lib/services/ocr/unavailable_ocr_engine.dart`
- Test: `test/ocr_model_test.dart` (create)

**Interfaces:**
- Consumes: nothing
- Produces:
  - `class OcrWord { String text; Rect boundsPx; double confidence; }`
  - `class OcrLine { String text; Rect boundsPx; List<OcrWord> words; }`
  - `class OcrResult { List<OcrLine> lines; Size imageSize; String get plainText; }`
  - `class OcrAvailability { bool available; String? reason; List<String> languages; }`
  - `abstract class OcrEngine { Future<OcrAvailability> availability(); Future<OcrResult> recognize(Uint8List pngBytes); }`
  - `OcrResult.fromChannelMap(Map<Object?, Object?>)`

- [ ] **Step 1: Write the failing test**

Create `test/ocr_model_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/services/ocr/ocr_engine.dart';

void main() {
  test('parses a channel payload into lines and words', () {
    final result = OcrResult.fromChannelMap(const {
      'width': 800,
      'height': 600,
      'lines': [
        {
          'text': 'Hello world',
          'x': 10.0,
          'y': 20.0,
          'w': 100.0,
          'h': 18.0,
          'confidence': 0.94,
          'words': [
            {'text': 'Hello', 'x': 10.0, 'y': 20.0, 'w': 44.0, 'h': 18.0, 'confidence': 0.96},
            {'text': 'world', 'x': 58.0, 'y': 20.0, 'w': 52.0, 'h': 18.0, 'confidence': 0.92},
          ],
        },
      ],
    });

    expect(result.imageSize, const Size(800, 600));
    expect(result.lines, hasLength(1));
    expect(result.lines.single.boundsPx, const Rect.fromLTWH(10, 20, 100, 18));
    expect(result.lines.single.words, hasLength(2));
    expect(result.lines.single.words.first.text, 'Hello');
    expect(result.plainText, 'Hello world');
  });

  test('joins multiple lines with newlines', () {
    final result = OcrResult.fromChannelMap(const {
      'width': 10,
      'height': 10,
      'lines': [
        {'text': 'one', 'x': 0.0, 'y': 0.0, 'w': 1.0, 'h': 1.0, 'confidence': 1.0, 'words': []},
        {'text': 'two', 'x': 0.0, 'y': 2.0, 'w': 1.0, 'h': 1.0, 'confidence': 1.0, 'words': []},
      ],
    });
    expect(result.plainText, 'one\ntwo');
  });

  test('tolerates a payload with no lines', () {
    final result = OcrResult.fromChannelMap(const {'width': 5, 'height': 5, 'lines': []});
    expect(result.lines, isEmpty);
    expect(result.plainText, isEmpty);
    expect(result.isEmpty, isTrue);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/ocr_model_test.dart`
Expected: FAIL — `Target of URI doesn't exist`.

- [ ] **Step 3: Implement the model**

Create `lib/services/ocr/ocr_engine.dart`:

```dart
import 'dart:typed_data';

import 'package:flutter/painting.dart';

/// One recognised word, positioned in **native image pixels**.
@immutable
class OcrWord {
  final String text;
  final Rect boundsPx;
  final double confidence;

  const OcrWord({
    required this.text,
    required this.boundsPx,
    required this.confidence,
  });
}

/// One recognised line, positioned in native image pixels.
@immutable
class OcrLine {
  final String text;
  final Rect boundsPx;
  final double confidence;
  final List<OcrWord> words;

  const OcrLine({
    required this.text,
    required this.boundsPx,
    required this.confidence,
    this.words = const [],
  });
}

/// The full recognition result for one image.
@immutable
class OcrResult {
  final List<OcrLine> lines;
  final Size imageSize;

  const OcrResult({required this.lines, required this.imageSize});

  static const OcrResult empty = OcrResult(lines: [], imageSize: Size.zero);

  bool get isEmpty => lines.isEmpty;

  String get plainText => lines.map((l) => l.text).join('\n');

  static Rect _rect(Map<Object?, Object?> m) => Rect.fromLTWH(
        (m['x'] as num).toDouble(),
        (m['y'] as num).toDouble(),
        (m['w'] as num).toDouble(),
        (m['h'] as num).toDouble(),
      );

  /// Builds a result from the `snipsnap/ocr` channel payload. Natives emit
  /// top-left-origin pixel coordinates, so no flipping happens here.
  factory OcrResult.fromChannelMap(Map<Object?, Object?> map) {
    final rawLines = (map['lines'] as List?) ?? const [];
    return OcrResult(
      imageSize: Size(
        (map['width'] as num?)?.toDouble() ?? 0,
        (map['height'] as num?)?.toDouble() ?? 0,
      ),
      lines: rawLines.map((raw) {
        final l = raw as Map<Object?, Object?>;
        final rawWords = (l['words'] as List?) ?? const [];
        return OcrLine(
          text: l['text'] as String? ?? '',
          boundsPx: _rect(l),
          confidence: (l['confidence'] as num?)?.toDouble() ?? 0.0,
          words: rawWords.map((rw) {
            final w = rw as Map<Object?, Object?>;
            return OcrWord(
              text: w['text'] as String? ?? '',
              boundsPx: _rect(w),
              confidence: (w['confidence'] as num?)?.toDouble() ?? 0.0,
            );
          }).toList(),
        );
      }).toList(),
    );
  }
}

/// Whether OCR can run on this host, and why not when it cannot.
@immutable
class OcrAvailability {
  final bool available;
  final String? reason;
  final List<String> languages;

  const OcrAvailability({
    required this.available,
    this.reason,
    this.languages = const [],
  });

  const OcrAvailability.unavailable(String this.reason)
      : available = false,
        languages = const [];
}

/// Recognises text in an image. One implementation per platform.
abstract class OcrEngine {
  Future<OcrAvailability> availability();

  /// [pngBytes] is a complete PNG. Callers crop before calling, so engines
  /// never deal with regions or coordinate systems.
  Future<OcrResult> recognize(Uint8List pngBytes);
}
```

Create `lib/services/ocr/unavailable_ocr_engine.dart`:

```dart
import 'dart:typed_data';

import 'ocr_engine.dart';

/// Used where no OCR engine ships with the OS. Reports why rather than
/// failing at call time, so the UI can disable the tool with an explanation.
class UnavailableOcrEngine implements OcrEngine {
  final String reason;

  const UnavailableOcrEngine(this.reason);

  @override
  Future<OcrAvailability> availability() async =>
      OcrAvailability.unavailable(reason);

  @override
  Future<OcrResult> recognize(Uint8List pngBytes) async => OcrResult.empty;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/ocr_model_test.dart`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/services/ocr/ test/ocr_model_test.dart
git commit -m "feat: add OcrEngine interface and result model"
```

---

## Task 11: `OcrService` — engine selection, region cropping, caching

**Files:**
- Create: `lib/services/ocr/ocr_service.dart`
- Create: `lib/services/ocr/channel_ocr_engine.dart`
- Test: `test/ocr_service_test.dart` (create)

**Interfaces:**
- Consumes: `OcrEngine`, `OcrResult`, `OcrAvailability` (Task 10); `CanvasProjection` (Task 2)
- Produces:
  - `OcrService({OcrEngine? engine})` — injectable for tests
  - `Future<OcrAvailability> availability()`
  - `Future<OcrResult> recognizeCapture({required String imagePath, required String cacheKey, Rect? regionPx})`
  - `void invalidate(String cacheKey)`
  - `class ChannelOcrEngine implements OcrEngine` over `MethodChannel('snipsnap/ocr')`

- [ ] **Step 1: Write the failing test**

Create `test/ocr_service_test.dart`:

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:snipsnap/services/ocr/ocr_engine.dart';
import 'package:snipsnap/services/ocr/ocr_service.dart';

class FakeOcrEngine implements OcrEngine {
  int recognizeCalls = 0;
  Uint8List? lastBytes;
  OcrAvailability availabilityResult =
      const OcrAvailability(available: true, languages: ['en-US']);

  @override
  Future<OcrAvailability> availability() async => availabilityResult;

  @override
  Future<OcrResult> recognize(Uint8List pngBytes) async {
    recognizeCalls++;
    lastBytes = pngBytes;
    final decoded = img.decodeImage(pngBytes)!;
    return OcrResult(
      imageSize: Size(decoded.width.toDouble(), decoded.height.toDouble()),
      lines: const [
        OcrLine(
          text: 'sample',
          boundsPx: Rect.fromLTWH(0, 0, 10, 10),
          confidence: 1.0,
        ),
      ],
    );
  }
}

Future<String> _writePng(Directory dir, int w, int h) async {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgb8(255, 255, 255));
  final path = '${dir.path}/src.png';
  await File(path).writeAsBytes(img.encodePng(image));
  return path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late FakeOcrEngine engine;
  late OcrService service;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('snipsnap_ocr_test');
    engine = FakeOcrEngine();
    service = OcrService(engine: engine);
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  test('recognizes the whole image when no region is given', () async {
    final path = await _writePng(tempDir, 400, 200);
    final result = await service.recognizeCapture(imagePath: path, cacheKey: 'k');
    expect(result.imageSize, const Size(400, 200));
    expect(engine.recognizeCalls, 1);
  });

  test('crops to the region before calling the engine', () async {
    final path = await _writePng(tempDir, 400, 200);
    await service.recognizeCapture(
      imagePath: path,
      cacheKey: 'k',
      regionPx: const Rect.fromLTWH(100, 50, 120, 60),
    );
    final decoded = img.decodeImage(engine.lastBytes!)!;
    expect(decoded.width, 120);
    expect(decoded.height, 60);
  });

  test('offsets region results back into full-image coordinates', () async {
    final path = await _writePng(tempDir, 400, 200);
    final result = await service.recognizeCapture(
      imagePath: path,
      cacheKey: 'k',
      regionPx: const Rect.fromLTWH(100, 50, 120, 60),
    );
    // The fake reports a line at (0,0) inside the crop; it must come back at
    // (100,50) in full-image space.
    expect(result.lines.single.boundsPx.left, 100);
    expect(result.lines.single.boundsPx.top, 50);
  });

  test('caches by key and re-runs after invalidation', () async {
    final path = await _writePng(tempDir, 400, 200);
    await service.recognizeCapture(imagePath: path, cacheKey: 'k');
    await service.recognizeCapture(imagePath: path, cacheKey: 'k');
    expect(engine.recognizeCalls, 1);

    service.invalidate('k');
    await service.recognizeCapture(imagePath: path, cacheKey: 'k');
    expect(engine.recognizeCalls, 2);
  });

  test('does not cache region results', () async {
    final path = await _writePng(tempDir, 400, 200);
    const region = Rect.fromLTWH(0, 0, 50, 50);
    await service.recognizeCapture(imagePath: path, cacheKey: 'k', regionPx: region);
    await service.recognizeCapture(imagePath: path, cacheKey: 'k', regionPx: region);
    expect(engine.recognizeCalls, 2);
  });

  test('returns empty for a region smaller than the minimum', () async {
    final path = await _writePng(tempDir, 400, 200);
    final result = await service.recognizeCapture(
      imagePath: path,
      cacheKey: 'k',
      regionPx: const Rect.fromLTWH(0, 0, 4, 4),
    );
    expect(result.isEmpty, isTrue);
    expect(engine.recognizeCalls, 0);
  });

  test('returns empty when the engine is unavailable', () async {
    engine.availabilityResult = const OcrAvailability.unavailable('no engine');
    final path = await _writePng(tempDir, 400, 200);
    final result = await service.recognizeCapture(imagePath: path, cacheKey: 'k');
    expect(result.isEmpty, isTrue);
    expect(engine.recognizeCalls, 0);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/ocr_service_test.dart`
Expected: FAIL — `Target of URI doesn't exist: '.../ocr_service.dart'`.

- [ ] **Step 3: Implement the channel engine**

Create `lib/services/ocr/channel_ocr_engine.dart`:

```dart
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'ocr_engine.dart';

/// Talks to the native OCR implementations over `snipsnap/ocr`.
///
/// macOS answers with Vision, Windows with Windows.Media.Ocr. Both emit
/// top-left-origin pixel coordinates, so this class does no geometry.
class ChannelOcrEngine implements OcrEngine {
  static const MethodChannel _channel = MethodChannel('snipsnap/ocr');

  const ChannelOcrEngine();

  @override
  Future<OcrAvailability> availability() async {
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>('availability');
      if (result == null) {
        return const OcrAvailability.unavailable('No response from the OCR engine.');
      }
      return OcrAvailability(
        available: result['available'] as bool? ?? false,
        reason: result['reason'] as String?,
        languages: ((result['languages'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
      );
    } on MissingPluginException {
      return const OcrAvailability.unavailable(
        'Text extraction is not available on this platform.',
      );
    } catch (e) {
      debugPrint('SnipSnap OCR availability error: $e');
      return OcrAvailability.unavailable('Could not reach the OCR engine: $e');
    }
  }

  @override
  Future<OcrResult> recognize(Uint8List pngBytes) async {
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'recognize',
        {'png': pngBytes},
      );
      if (result == null) return OcrResult.empty;
      return OcrResult.fromChannelMap(result);
    } catch (e) {
      debugPrint('SnipSnap OCR recognize error: $e');
      return OcrResult.empty;
    }
  }
}
```

- [ ] **Step 4: Implement the service**

Create `lib/services/ocr/ocr_service.dart`:

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:image/image.dart' as img;

import 'channel_ocr_engine.dart';
import 'ocr_engine.dart';
import 'unavailable_ocr_engine.dart';

/// Runs OCR over a capture, cropping to a region when asked and caching
/// full-image results per capture revision.
class OcrService {
  /// Regions below this many pixels on a side are almost always accidental
  /// click-drags and are not worth a round trip.
  static const double minRegionSide = 8.0;

  final OcrEngine engine;
  final Map<String, OcrResult> _cache = {};
  OcrAvailability? _availability;

  OcrService({OcrEngine? engine}) : engine = engine ?? _engineForPlatform();

  static OcrEngine _engineForPlatform() {
    if (Platform.isMacOS || Platform.isWindows) return const ChannelOcrEngine();
    return const UnavailableOcrEngine(
      'Text extraction needs an OCR engine from the operating system, which '
      'Linux does not provide. Available on macOS and Windows.',
    );
  }

  Future<OcrAvailability> availability() async =>
      _availability ??= await engine.availability();

  void invalidate(String cacheKey) => _cache.remove(cacheKey);

  void clearCache() => _cache.clear();

  /// Recognises text in [imagePath], optionally limited to [regionPx] in
  /// native image pixels.
  ///
  /// Full-image results are cached under [cacheKey] — callers pass a key that
  /// changes when the bitmap changes. Region results are never cached, since
  /// the region differs on every call.
  Future<OcrResult> recognizeCapture({
    required String imagePath,
    required String cacheKey,
    Rect? regionPx,
  }) async {
    final availability = await this.availability();
    if (!availability.available) return OcrResult.empty;

    if (regionPx != null &&
        (regionPx.width < minRegionSide || regionPx.height < minRegionSide)) {
      return OcrResult.empty;
    }

    if (regionPx == null) {
      final cached = _cache[cacheKey];
      if (cached != null) return cached;
    }

    try {
      final file = File(imagePath);
      if (!await file.exists()) return OcrResult.empty;
      final sourceBytes = await file.readAsBytes();

      if (regionPx == null) {
        final result = await engine.recognize(sourceBytes);
        _cache[cacheKey] = result;
        return result;
      }

      final decoded = img.decodeImage(sourceBytes);
      if (decoded == null) return OcrResult.empty;

      final x = regionPx.left.round().clamp(0, decoded.width - 1);
      final y = regionPx.top.round().clamp(0, decoded.height - 1);
      final w = regionPx.width.round().clamp(1, decoded.width - x);
      final h = regionPx.height.round().clamp(1, decoded.height - y);

      final cropped = img.copyCrop(decoded, x: x, y: y, width: w, height: h);
      final result = await engine.recognize(
        Uint8List.fromList(img.encodePng(cropped)),
      );
      return _offset(result, Offset(x.toDouble(), y.toDouble()));
    } catch (e) {
      debugPrint('SnipSnap OCR service error: $e');
      return OcrResult.empty;
    }
  }

  /// Shifts a region result back into full-image coordinates.
  static OcrResult _offset(OcrResult result, Offset delta) {
    if (delta == Offset.zero) return result;
    return OcrResult(
      imageSize: result.imageSize,
      lines: result.lines
          .map((l) => OcrLine(
                text: l.text,
                boundsPx: l.boundsPx.shift(delta),
                confidence: l.confidence,
                words: l.words
                    .map((w) => OcrWord(
                          text: w.text,
                          boundsPx: w.boundsPx.shift(delta),
                          confidence: w.confidence,
                        ))
                    .toList(),
              ))
          .toList(),
    );
  }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `flutter test test/ocr_service_test.dart`
Expected: PASS (7 tests)

- [ ] **Step 6: Verify**

Run: `flutter test && flutter analyze`
Expected: all pass, `No issues found!`

- [ ] **Step 7: Commit**

```bash
git add lib/services/ocr/ test/ocr_service_test.dart
git commit -m "feat: add OcrService with region cropping and per-capture caching"
```

---

## Task 12: macOS Vision implementation

**Files:**
- Create: `macos/Runner/OcrPlugin.swift`
- Modify: `macos/Runner/MainFlutterWindow.swift`

**Interfaces:**
- Consumes: the `snipsnap/ocr` contract from Task 11 (`availability`, `recognize`)
- Produces: a working macOS engine. No Dart changes.

- [ ] **Step 1: Write the plugin**

Create `macos/Runner/OcrPlugin.swift`:

```swift
import AppKit
import FlutterMacOS
import Vision

/// Bridges `snipsnap/ocr` to Vision's text recogniser.
///
/// Vision reports normalised boxes with a bottom-left origin; everything here
/// is converted to top-left-origin pixels so Dart only ever sees one
/// convention.
class OcrPlugin: NSObject {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "snipsnap/ocr",
      binaryMessenger: registrar.messenger
    )
    let instance = OcrPlugin()
    channel.setMethodCallHandler { call, result in
      instance.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "availability":
      result(availability())
    case "recognize":
      guard
        let args = call.arguments as? [String: Any],
        let data = args["png"] as? FlutterStandardTypedData
      else {
        result(FlutterError(code: "bad_args", message: "png bytes missing", details: nil))
        return
      }
      recognize(data.data, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func supportedLanguages() -> [String] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    return (try? request.supportedRecognitionLanguages()) ?? []
  }

  private func availability() -> [String: Any] {
    let languages = supportedLanguages()
    if languages.isEmpty {
      return [
        "available": false,
        "reason": "Vision reported no recognition languages on this Mac.",
        "languages": [String](),
      ]
    }
    return ["available": true, "languages": languages]
  }

  private func recognize(_ data: Data, result: @escaping FlutterResult) {
    guard
      let image = NSImage(data: data),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else {
      result(FlutterError(code: "decode_failed", message: "Could not decode PNG", details: nil))
      return
    }

    let width = CGFloat(cgImage.width)
    let height = CGFloat(cgImage.height)

    let request = VNRecognizeTextRequest { request, error in
      if let error = error {
        result(FlutterError(code: "recognize_failed", message: error.localizedDescription, details: nil))
        return
      }

      let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
      var lines: [[String: Any]] = []

      for observation in observations {
        guard let candidate = observation.topCandidates(1).first else { continue }

        var words: [[String: Any]] = []
        // Per-word boxes come from ranges inside the candidate's string.
        for range in candidate.string.wordRanges {
          guard let box = try? candidate.boundingBox(for: range) else { continue }
          words.append(
            Self.rectPayload(
              text: String(candidate.string[range]),
              box: box.boundingBox,
              width: width,
              height: height,
              confidence: Double(candidate.confidence)
            )
          )
        }

        var line = Self.rectPayload(
          text: candidate.string,
          box: observation.boundingBox,
          width: width,
          height: height,
          confidence: Double(candidate.confidence)
        )
        line["words"] = words
        lines.append(line)
      }

      result([
        "width": Int(width),
        "height": Int(height),
        "lines": lines,
      ])
    }

    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true

    // Revision 3 needs macOS 13; fall back cleanly on macOS 12.
    if #available(macOS 13.0, *) {
      request.revision = VNRecognizeTextRequestRevision3
    } else {
      request.revision = VNRecognizeTextRequestRevision2
    }

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        try handler.perform([request])
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "recognize_failed", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  /// Converts a Vision normalised, bottom-left-origin box into a top-left
  /// origin pixel rect.
  private static func rectPayload(
    text: String,
    box: CGRect,
    width: CGFloat,
    height: CGFloat,
    confidence: Double
  ) -> [String: Any] {
    let x = box.minX * width
    let w = box.width * width
    let h = box.height * height
    let y = (1.0 - box.maxY) * height
    return [
      "text": text,
      "x": Double(x),
      "y": Double(y),
      "w": Double(w),
      "h": Double(h),
      "confidence": confidence,
    ]
  }
}

private extension String {
  /// Ranges of each whitespace-separated word, used for per-word boxes.
  var wordRanges: [Range<String.Index>] {
    var ranges: [Range<String.Index>] = []
    var start: String.Index? = nil
    for index in indices {
      let isSpace = self[index].isWhitespace
      if !isSpace && start == nil {
        start = index
      } else if isSpace, let s = start {
        ranges.append(s..<index)
        start = nil
      }
    }
    if let s = start { ranges.append(s..<endIndex) }
    return ranges
  }
}
```

- [ ] **Step 2: Register the plugin**

In `macos/Runner/MainFlutterWindow.swift`, after `RegisterGeneratedPlugins`:

```swift
    RegisterGeneratedPlugins(registry: flutterViewController)
    OcrPlugin.register(with: flutterViewController.registrar(forPlugin: "OcrPlugin"))
```

- [ ] **Step 3: Add the file to the Xcode target**

Run: `open macos/Runner.xcworkspace`

In Xcode, drag `OcrPlugin.swift` into the `Runner` group and confirm it appears
under Build Phases → Compile Sources for the `Runner` target. Without this the
file is ignored and `availability` returns `MissingPluginException`.

- [ ] **Step 4: Build and smoke-test**

Run: `flutter run -d macos`

Add a temporary debug button or use the Dart DevTools console to call:

```dart
await OcrService().availability();
```

Expected: `available: true` with a non-empty language list.

- [ ] **Step 5: Verify analyzer and suite**

Run: `flutter test && flutter analyze`
Expected: all pass, `No issues found!`

- [ ] **Step 6: Commit**

```bash
git add macos/
git commit -m "feat: add macOS Vision OCR implementation"
```

---

## Task 13: Windows `Media.Ocr` implementation

**Requires a Windows host or VM.** If none is available, stop after Task 12,
ship macOS, and return to this task later — `OcrService` already degrades on
platforms without an engine, so nothing else is blocked.

**Files:**
- Create: `windows/runner/ocr_handler.h`, `windows/runner/ocr_handler.cpp`
- Modify: `windows/runner/CMakeLists.txt:9` (sources), `:36` (libraries)
- Modify: `windows/runner/flutter_window.cpp:29` (registration)

**Interfaces:**
- Consumes: the `snipsnap/ocr` contract from Task 11
- Produces: a working Windows engine. No Dart changes.

- [ ] **Step 1: Write the handler header**

Create `windows/runner/ocr_handler.h`:

```cpp
#ifndef RUNNER_OCR_HANDLER_H_
#define RUNNER_OCR_HANDLER_H_

#include <flutter/flutter_engine.h>

// Registers the `snipsnap/ocr` channel against Windows.Media.Ocr.
void RegisterOcrHandler(flutter::FlutterEngine* engine);

#endif  // RUNNER_OCR_HANDLER_H_
```

- [ ] **Step 2: Write the handler implementation**

Create `windows/runner/ocr_handler.cpp`:

```cpp
#include "ocr_handler.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Globalization.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Media.Ocr.h>
#include <winrt/Windows.Storage.Streams.h>

#include <memory>
#include <string>
#include <vector>

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

namespace {

std::string ToUtf8(winrt::hstring const& value) {
  return winrt::to_string(value);
}

// Builds an OCR engine from the user's languages, falling back to any
// installed recognizer. Returns nullptr when no language pack is present.
winrt::Windows::Media::Ocr::OcrEngine CreateEngine() {
  auto engine =
      winrt::Windows::Media::Ocr::OcrEngine::TryCreateFromUserProfileLanguages();
  if (engine) return engine;

  auto languages =
      winrt::Windows::Media::Ocr::OcrEngine::AvailableRecognizerLanguages();
  if (languages.Size() == 0) return nullptr;
  return winrt::Windows::Media::Ocr::OcrEngine::TryCreateFromLanguage(
      languages.GetAt(0));
}

void HandleAvailability(
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  EncodableList languages;
  for (auto const& language :
       winrt::Windows::Media::Ocr::OcrEngine::AvailableRecognizerLanguages()) {
    languages.push_back(EncodableValue(ToUtf8(language.LanguageTag())));
  }

  if (languages.empty()) {
    result->Success(EncodableValue(EncodableMap{
        {EncodableValue("available"), EncodableValue(false)},
        {EncodableValue("reason"),
         EncodableValue("No OCR language pack is installed. Add one in "
                        "Settings > Time & language > Language & region.")},
        {EncodableValue("languages"), EncodableValue(EncodableList{})},
    }));
    return;
  }

  result->Success(EncodableValue(EncodableMap{
      {EncodableValue("available"), EncodableValue(true)},
      {EncodableValue("languages"), EncodableValue(languages)},
  }));
}

EncodableMap RectPayload(std::string text,
                         winrt::Windows::Foundation::Rect const& rect,
                         double confidence) {
  return EncodableMap{
      {EncodableValue("text"), EncodableValue(std::move(text))},
      {EncodableValue("x"), EncodableValue(static_cast<double>(rect.X))},
      {EncodableValue("y"), EncodableValue(static_cast<double>(rect.Y))},
      {EncodableValue("w"), EncodableValue(static_cast<double>(rect.Width))},
      {EncodableValue("h"), EncodableValue(static_cast<double>(rect.Height))},
      {EncodableValue("confidence"), EncodableValue(confidence)},
  };
}

void HandleRecognize(
    const std::vector<uint8_t>& png,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  auto engine = CreateEngine();
  if (!engine) {
    result->Error("no_engine", "No OCR language pack is installed.");
    return;
  }

  using namespace winrt::Windows::Storage::Streams;
  InMemoryRandomAccessStream stream;
  DataWriter writer(stream);
  writer.WriteBytes(winrt::array_view<const uint8_t>(png));
  writer.StoreAsync().get();
  writer.FlushAsync().get();
  stream.Seek(0);

  auto decoder =
      winrt::Windows::Graphics::Imaging::BitmapDecoder::CreateAsync(stream).get();
  auto bitmap = decoder.GetSoftwareBitmapAsync().get();

  auto ocrResult = engine.RecognizeAsync(bitmap).get();

  EncodableList lines;
  for (auto const& line : ocrResult.Lines()) {
    EncodableList words;
    // Windows gives per-word rects directly; the line rect is their union.
    float left = 0, top = 0, right = 0, bottom = 0;
    bool first = true;
    for (auto const& word : line.Words()) {
      auto const& r = word.BoundingRect();
      words.push_back(EncodableValue(RectPayload(ToUtf8(word.Text()), r, 1.0)));
      if (first) {
        left = r.X;
        top = r.Y;
        right = r.X + r.Width;
        bottom = r.Y + r.Height;
        first = false;
      } else {
        left = min(left, r.X);
        top = min(top, r.Y);
        right = max(right, r.X + r.Width);
        bottom = max(bottom, r.Y + r.Height);
      }
    }

    winrt::Windows::Foundation::Rect lineRect{left, top, right - left,
                                              bottom - top};
    auto payload = RectPayload(ToUtf8(line.Text()), lineRect, 1.0);
    payload[EncodableValue("words")] = EncodableValue(words);
    lines.push_back(EncodableValue(payload));
  }

  result->Success(EncodableValue(EncodableMap{
      {EncodableValue("width"), EncodableValue(static_cast<int32_t>(bitmap.PixelWidth()))},
      {EncodableValue("height"), EncodableValue(static_cast<int32_t>(bitmap.PixelHeight()))},
      {EncodableValue("lines"), EncodableValue(lines)},
  }));
}

}  // namespace

void RegisterOcrHandler(flutter::FlutterEngine* engine) {
  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      engine->messenger(), "snipsnap/ocr",
      &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        try {
          if (call.method_name() == "availability") {
            HandleAvailability(std::move(result));
            return;
          }
          if (call.method_name() == "recognize") {
            const auto* args = std::get_if<EncodableMap>(call.arguments());
            if (!args) {
              result->Error("bad_args", "Expected a map");
              return;
            }
            auto it = args->find(EncodableValue("png"));
            if (it == args->end()) {
              result->Error("bad_args", "png bytes missing");
              return;
            }
            const auto& png = std::get<std::vector<uint8_t>>(it->second);
            HandleRecognize(png, std::move(result));
            return;
          }
          result->NotImplemented();
        } catch (const winrt::hresult_error& e) {
          result->Error("winrt_error", ToUtf8(e.message()));
        }
      });

  // The channel must outlive this call.
  static std::unique_ptr<flutter::MethodChannel<EncodableValue>> retained;
  retained = std::move(channel);
}
```

- [ ] **Step 3: Wire it into the build**

In `windows/runner/CMakeLists.txt`, add the source to `add_executable`:

```cmake
  "ocr_handler.cpp"
```

and link WinRT:

```cmake
target_link_libraries(${BINARY_NAME} PRIVATE "windowsapp.lib")
```

- [ ] **Step 4: Register at startup**

In `windows/runner/flutter_window.cpp`, add `#include "ocr_handler.h"` and,
after `RegisterPlugins(flutter_controller_->engine());`:

```cpp
  RegisterOcrHandler(flutter_controller_->engine());
```

Add `winrt::init_apartment(winrt::apartment_type::single_threaded);` at the top
of `main()` in `windows/runner/main.cpp`, with `#include <winrt/base.h>`.

- [ ] **Step 5: Build and smoke-test**

Run: `flutter run -d windows`

Call `await OcrService().availability();` and expect `available: true`. On a
machine with no OCR language pack, expect `available: false` with the Settings
message — verify that path too, since it is the common failure.

- [ ] **Step 6: Commit**

```bash
git add windows/
git commit -m "feat: add Windows Media.Ocr implementation"
```

---

## Task 14: The OCR tool and result panel

**Files:**
- Modify: `lib/utils/constants.dart:5-19` (add `CanvasTool.ocr`)
- Create: `lib/tools/ocr_tool.dart`
- Modify: `lib/tools/tool_handler.dart` (delegate hook + factory case)
- Modify: `lib/views/components/tool_sidebar.dart:96-108` (sidebar entry)
- Modify: `lib/models/tool_properties.dart:100-124` (defaults)
- Create: `lib/views/components/ocr_result_panel.dart`
- Modify: `lib/views/editor_canvas.dart` (region drag, panel host, `E` shortcut)
- Test: `test/ocr_tool_test.dart` (create)

**Interfaces:**
- Consumes: `OcrService` (Task 11), `handlerFor` (Task 9), `CanvasProjection` (Task 2)
- Produces:
  - `CanvasTool.ocr`
  - `OcrToolHandler`
  - `ToolDelegate.onExtractText(Rect? canvasRegion)`
  - `OcrResultPanel({required OcrResult result, required VoidCallback onClose, required ValueChanged<String> onInsertAsText, required bool isDarkMode})`

- [ ] **Step 1: Add the enum value and defaults**

In `lib/utils/constants.dart`, add to `CanvasTool` after `colorPicker`:

```dart
  /// Extracts text from the capture using the platform OCR engine.
  ocr,
```

In `lib/models/tool_properties.dart`, add to `createDefaults()`:

```dart
      CanvasTool.ocr: const ToolProperties(activeColor: AppColors.accent),
```

- [ ] **Step 2: Write the failing test**

Create `test/ocr_tool_test.dart`:

```dart
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/tools/ocr_tool.dart';
import 'package:snipsnap/tools/tool_handler.dart';
import 'package:snipsnap/utils/constants.dart';

import 'tool_handlers_test.dart' show MockToolDelegate;

DragStartDetails _dragStart(Offset p) => DragStartDetails(localPosition: p);
DragUpdateDetails _dragUpdate(Offset p) => DragUpdateDetails(globalPosition: p, localPosition: p);
DragEndDetails _dragEnd() => DragEndDetails();
TapUpDetails _tapUp(Offset p) =>
    TapUpDetails(kind: PointerDeviceKind.mouse, localPosition: p);

void main() {
  test('handlerFor returns the OCR handler', () {
    expect(handlerFor(CanvasTool.ocr, MockToolDelegate()), isA<OcrToolHandler>());
  });

  test('a drag requests extraction for that region', () {
    final delegate = MockToolDelegate();
    final handler = OcrToolHandler(delegate);

    handler.onPanStart(_dragStart(const Offset(10, 10)), const Offset(10, 10));
    handler.onPanUpdate(_dragUpdate(const Offset(120, 90)), const Offset(120, 90));
    handler.onPanEnd(_dragEnd());

    expect(delegate.extractTextRegions, hasLength(1));
    expect(delegate.extractTextRegions.single, const Rect.fromLTRB(10, 10, 120, 90));
  });

  test('a tap with no drag requests whole-image extraction', () {
    final delegate = MockToolDelegate();
    final handler = OcrToolHandler(delegate);

    handler.onTapUp(_tapUp(const Offset(40, 40)), const Offset(40, 40));

    expect(delegate.extractTextRegions, hasLength(1));
    expect(delegate.extractTextRegions.single, isNull);
  });

  test('a negligible drag is treated as a tap', () {
    final delegate = MockToolDelegate();
    final handler = OcrToolHandler(delegate);

    handler.onPanStart(_dragStart(const Offset(10, 10)), const Offset(10, 10));
    handler.onPanUpdate(_dragUpdate(const Offset(12, 11)), const Offset(12, 11));
    handler.onPanEnd(_dragEnd());

    expect(delegate.extractTextRegions.single, isNull);
  });
}
```

Add the tracking field to `MockToolDelegate` in `test/tool_handlers_test.dart`:

```dart
  final List<Rect?> extractTextRegions = [];

  @override
  void onExtractText(Rect? canvasRegion) => extractTextRegions.add(canvasRegion);
```

- [ ] **Step 3: Run test to verify it fails**

Run: `flutter test test/ocr_tool_test.dart`
Expected: FAIL — `Target of URI doesn't exist: '.../ocr_tool.dart'`.

- [ ] **Step 4: Add the delegate hook**

In `lib/tools/tool_handler.dart`, add to `ToolDelegate`:

```dart
  /// Requests text extraction. A null region means the whole capture.
  void onExtractText(Rect? canvasRegion);
```

and add the factory case:

```dart
    case CanvasTool.ocr:
      return OcrToolHandler(delegate);
```

- [ ] **Step 5: Implement the handler**

Create `lib/tools/ocr_tool.dart`:

```dart
import 'package:flutter/material.dart';

import 'tool_handler.dart';

/// Selects a region to extract text from. A drag extracts that region; a click
/// with no meaningful drag extracts the whole capture.
class OcrToolHandler extends ToolHandler {
  /// Below this, a drag is indistinguishable from a click and is treated as one.
  static const double minDragSide = 8.0;

  Offset? _start;
  Offset? _end;

  OcrToolHandler(super.delegate);

  @override
  void onPanStart(DragStartDetails details, Offset pos) {
    _start = pos;
    _end = pos;
  }

  @override
  void onPanUpdate(DragUpdateDetails details, Offset pos) {
    _end = pos;
  }

  @override
  void onPanEnd(DragEndDetails details) {
    final start = _start;
    final end = _end;
    _start = null;
    _end = null;
    if (start == null || end == null) return;

    final rect = Rect.fromPoints(start, end);
    delegate.onExtractText(
      rect.width < minDragSide || rect.height < minDragSide ? null : rect,
    );
  }

  @override
  void onTapUp(TapUpDetails details, Offset pos) {
    delegate.onExtractText(null);
  }
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `flutter test test/ocr_tool_test.dart`
Expected: PASS (4 tests)

- [ ] **Step 7: Implement the delegate method on the canvas**

In `lib/views/editor_canvas.dart`, add the widget callback:

```dart
  final void Function(Rect? imageRegionPx)? onExtractText;
```

(and the matching constructor parameter `this.onExtractText,`), then implement:

```dart
  @override
  void onExtractText(Rect? canvasRegion) {
    final p = _projection;
    if (!p.isValid) return;
    widget.onExtractText?.call(
      canvasRegion == null ? null : p.toImageRect(canvasRegion),
    );
  }
```

The handler works in canvas coordinates and the service needs image pixels, so
this is the only place the two meet.

- [ ] **Step 8: Add the sidebar entry and shortcut**

In `lib/views/components/tool_sidebar.dart`, after the `fill` entry:

```dart
    ToolSidebarItem(CanvasTool.ocr, Icons.text_snippet_outlined, 'Text', 'Extract text from the image  (E)'),
```

In `lib/views/editor_canvas.dart`'s `toolKeys` map:

```dart
      LogicalKeyboardKey.keyE: CanvasTool.ocr,
```

- [ ] **Step 9: Build the result panel**

Create `lib/views/components/ocr_result_panel.dart`:

```dart
import 'package:flutter/material.dart';

import '../../services/clipboard_service.dart';
import '../../services/ocr/ocr_engine.dart';
import '../../utils/constants.dart';

/// Shows extracted text with copy and insert actions.
class OcrResultPanel extends StatelessWidget {
  final OcrResult result;
  final bool isLoading;
  final String? unavailableReason;
  final VoidCallback onClose;
  final ValueChanged<String> onInsertAsText;
  final bool isDarkMode;

  const OcrResultPanel({
    super.key,
    required this.result,
    required this.onClose,
    required this.onInsertAsText,
    required this.isDarkMode,
    this.isLoading = false,
    this.unavailableReason,
  });

  @override
  Widget build(BuildContext context) {
    final surface = isDarkMode ? AppColors.darkSurface : AppColors.lightSurface;
    final textColor = isDarkMode ? Colors.white : Colors.black87;
    final subTextColor = isDarkMode ? Colors.white54 : Colors.black54;

    return Container(
      width: 320,
      constraints: const BoxConstraints(maxHeight: 420),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isDarkMode ? Colors.white12 : Colors.black12),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text('Extracted text',
                  style: TextStyle(color: textColor, fontWeight: FontWeight.w600)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                color: subTextColor,
                onPressed: onClose,
                tooltip: 'Close',
              ),
            ],
          ),
          const SizedBox(height: 8),
          Flexible(child: _buildBody(textColor, subTextColor)),
          if (!isLoading && unavailableReason == null && !result.isEmpty) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  label: const Text('Copy'),
                  onPressed: () => ClipboardService.copyText(result.plainText),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  icon: const Icon(Icons.text_fields_rounded, size: 16),
                  label: const Text('Insert'),
                  onPressed: () => onInsertAsText(result.plainText),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBody(Color textColor, Color subTextColor) {
    if (isLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: SizedBox(
          width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2),
        )),
      );
    }
    if (unavailableReason != null) {
      return Text(unavailableReason!, style: TextStyle(color: subTextColor, fontSize: 13));
    }
    if (result.isEmpty) {
      return Text('No text found in this area.',
          style: TextStyle(color: subTextColor, fontSize: 13));
    }
    return SingleChildScrollView(
      child: SelectableText(
        result.plainText,
        style: TextStyle(color: textColor, fontSize: 13, height: 1.5),
      ),
    );
  }
}
```

- [ ] **Step 10: Host the panel from `MainScreen`**

In `lib/views/main_screen.dart`, add state and the handler:

```dart
  final OcrService _ocrService = OcrService();
  OcrResult? _ocrResult;
  bool _isOcrRunning = false;
  String? _ocrUnavailableReason;

  Future<void> _handleExtractText(Rect? imageRegionPx) async {
    final capture = _activeCapture;
    if (capture == null) return;

    final availability = await _ocrService.availability();
    if (!availability.available) {
      setState(() {
        _ocrUnavailableReason = availability.reason;
        _ocrResult = OcrResult.empty;
      });
      return;
    }

    setState(() {
      _isOcrRunning = true;
      _ocrUnavailableReason = null;
      _ocrResult = OcrResult.empty;
    });

    final result = await _ocrService.recognizeCapture(
      imagePath: capture.filePath,
      cacheKey: '${capture.id}_$_imageRevision',
      regionPx: imageRegionPx,
    );

    if (!mounted) return;
    setState(() {
      _isOcrRunning = false;
      _ocrResult = result;
    });
  }
```

Pass `onExtractText: _handleExtractText` to `EditorCanvas`, and render
`OcrResultPanel` in the editor stack when `_ocrResult != null`. Insert-as-text
reuses the existing annotation path:

```dart
    onInsertAsText: (text) {
      final annotation = Annotation(
        id: const Uuid().v4(),
        tool: CanvasTool.text,
        color: _currentToolProperties.activeColor,
        backgroundColor: _currentToolProperties.textBackgroundColor,
        fontSize: _currentToolProperties.fontSize,
        text: text,
        startPoint: const Offset(40, 40),
      );
      _onAnnotationAdded(annotation);
      setState(() => _ocrResult = null);
    },
```

Note the inserted annotation's `startPoint` is in image pixels, matching the
storage space established in Task 6.

- [ ] **Step 11: Invalidate the cache when the bitmap changes**

Anywhere `_imageRevision++` happens (crop, flatten, flood fill, undo), the
cache key changes automatically because it embeds `_imageRevision`. Add an
explicit clear when the active capture changes:

```dart
    _ocrService.clearCache();
    _ocrResult = null;
```

inside the capture-selection setState in `_selectCapture` and
`_addCaptureFromPath`.

- [ ] **Step 12: Verify**

Run: `flutter test && flutter analyze`
Expected: all pass, `No issues found!`

- [ ] **Step 13: Manual end-to-end test**

Run: `flutter run -d macos`

1. Capture or import a screenshot containing text.
2. Press `E`, drag over a paragraph. Text appears in the panel within a second.
3. Copy — paste elsewhere and confirm it matches.
4. Insert — confirm a text annotation appears and persists across a restart.
5. Click without dragging — the whole image is recognised.
6. Drag a 3px box — nothing happens, no error.
7. Crop the image, run OCR again — results reflect the new bitmap, not the cache.

- [ ] **Step 14: Commit**

```bash
git add lib/ test/
git commit -m "feat: add the text extraction tool and result panel"
```

---

# Self-Review Notes

**Spec coverage.** Spec §1.1 → Tasks 12, 13. §1.2 → Tasks 10, 11. §1.3 → Tasks
12, 13. §1.4 → Task 14. §1.5 → Tasks 11, 14. §2.1 → Tasks 1–7. §2.2 → Task 7.
§2.3 → Tasks 8, 9. §2.4 `copyWith` sentinel → Task 3; failing test → Task 8. The
remaining §2.4 rows (`wl-copy`, `snippingtool`, temp files, undo budget, script
injection) and all of Part 3 (theming) are Phases 4–5 and are deliberately not
in this plan.

**Deviation from the spec, recorded.** §2.1 assumed capture dimensions were
usually present; they are never populated, so Task 1 was added ahead of the
migration. §2.1 also discussed geometry only, but stroke width, font size,
corner radius and blur sigma are canvas-scaled too — Task 3 converts them, and
`CanvasProjection.toImageLength` exists for that reason.

**Known follow-up.** `EditorCanvas` still owns crop, floating-selection and
transform-handle gestures after Task 9; only tool-specific drawing moves to the
handlers. Splitting the remaining ~1,800 lines is out of scope here.
