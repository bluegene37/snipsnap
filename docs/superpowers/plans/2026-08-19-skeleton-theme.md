# Skeleton Theme Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace SnipSnap's Electric Violet chrome with a monochrome "skeleton" design language in light and dark variants, driven by a token layer instead of 220 hardcoded `isDarkMode` ternaries.

**Architecture:** A `SnipTheme` value object carries every chrome colour and metric. It is provided once at the root by an `InheritedWidget` and read as `SnipTheme.of(context)`. Widgets stop branching on a boolean and stop referencing `AppColors` chrome constants. Because skeleton removes both colour and fill — the two things the app currently uses to signal state — **inversion becomes the state signal**: inactive controls are hairline outlines, the active one is a solid ink plate with its icon knocked out.

**Tech Stack:** Flutter (Dart SDK ^3.12.2), `google_fonts`, existing Drift-backed settings.

**Spec:** `docs/superpowers/specs/2026-08-18-ocr-and-production-hardening-design.md`, Part 3.

## Global Constraints

- Dart SDK `^3.12.2`, `flutter_lints ^6.0.0`. `flutter analyze` must report zero issues after every task.
- The suite is green at **200/200**. It must stay green. Anything red is a real regression.
- **DO NOT launch the app** (`flutter run`). It runs an irreversible coordinate migration against the user's real 42-capture library.
- `flutter_tester` **hangs indefinitely** on any widget tree containing `Image.file`, which `EditorCanvas.build` emits whenever `imagePath != null`. `EditorCanvas` cannot be pumped. Widgets that do not embed a capture (sidebars, dialogs, panels, the header) CAN be widget-tested — do that.
- Do NOT rename or reformat these five signatures in `editor_canvas.dart` — source-level tests key on their literal text: `_emitAnnotation`, `_replaceAnnotation`, `_canvasAnnotationsFor`, `_selectedAnnotation`, `hitTestAnnotation`.
- **Annotation rendering is out of scope.** `AnnotationRenderer` and every annotation colour stay exactly as they are. This plan changes chrome only.
- Commit after every task.

## The mapping, applied everywhere

Every task below applies this table. It is the whole conversion.

| Current | Becomes | Notes |
|---|---|---|
| `widget.isDarkMode ? X : Y` | a `SnipTheme` token | delete the parameter once the file is converted |
| `AppColors.accent` (chrome) | `t.ink` for marks/text, `t.activeFill` for a selected plate | 159 sites; the bulk of the work |
| `AppColors.accentHover` | `t.borderStrong` | |
| `AppColors.darkBg` / `lightBg` | `t.canvas` | |
| `AppColors.darkSurface` / `lightSurface` | `t.surface` | |
| `AppColors.darkSurfaceVariant` / `lightSurfaceVariant` | `t.surfaceRaised` | |
| `AppColors.sidebarBg` / `sidebarBgLight` | `t.surface` | |
| `AppColors.canvasBg` / `canvasBgLight` | `t.canvas` | |
| `Colors.white12` / `Colors.black12` borders | `t.border` | |
| `Colors.white54` / `Colors.black54` | `t.inkMuted` | |
| `Colors.white` / `Colors.black87` body text | `t.ink` | |
| `AppColors.palette` | **unchanged** | annotation swatches are data |
| `AppColors.framingGradients` | **unchanged** | user-selected export decorations |

**State treatment, applied to every control:**

| State | Treatment |
|---|---|
| Inactive | `Border.all(color: t.border, width: t.hairline)`, label `t.inkMuted`, no fill |
| Hover | border becomes `t.borderStrong`; no fill, no movement |
| **Active / selected** | fill `t.activeFill`, icon and label `t.onActive` |
| Disabled | dashed or faint border, label at 40% |
| Focused | 1px offset ring in `t.ink` |

---

## Task 1: The `SnipTheme` token layer

**Files:**
- Create: `lib/utils/snip_theme.dart`
- Test: `test/snip_theme_test.dart`

**Interfaces:**
- Consumes: nothing
- Produces: `SnipThemeMode { light, dark }`; `SnipTheme` with fields `canvas, surface, surfaceRaised, ink, inkMuted, inkFaint, border, borderStrong, activeFill, onActive, hairline, activeBorderWidth, radius, mode`; `SnipTheme.light()`, `SnipTheme.dark()`, `SnipTheme.forMode(SnipThemeMode)`; `SnipThemeScope` InheritedWidget with `static SnipTheme of(BuildContext)`.

- [ ] **Step 1: Write the failing test**

Create `test/snip_theme_test.dart`:

```dart
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/utils/snip_theme.dart';

/// WCAG relative luminance.
double _luminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  test('every mode resolves a complete token set', () {
    for (final mode in SnipThemeMode.values) {
      final t = SnipTheme.forMode(mode);
      expect(t.mode, mode);
      // A mode may never ship with a null colour.
      expect(
        [t.canvas, t.surface, t.surfaceRaised, t.ink, t.inkMuted, t.inkFaint,
         t.border, t.borderStrong, t.activeFill, t.onActive],
        everyElement(isA<Color>()),
        reason: '$mode has an incomplete token set',
      );
      expect(t.hairline, greaterThan(0));
      expect(t.radius, greaterThanOrEqualTo(0));
    }
  });

  test('ink on surface meets WCAG AA in both modes', () {
    for (final mode in SnipThemeMode.values) {
      final t = SnipTheme.forMode(mode);
      expect(_contrast(t.ink, t.surface), greaterThanOrEqualTo(4.5),
          reason: '$mode: ink on surface');
      expect(_contrast(t.ink, t.canvas), greaterThanOrEqualTo(4.5),
          reason: '$mode: ink on canvas');
    }
  });

  test('knocked-out label on an active plate meets WCAG AA', () {
    for (final mode in SnipThemeMode.values) {
      final t = SnipTheme.forMode(mode);
      expect(_contrast(t.onActive, t.activeFill), greaterThanOrEqualTo(4.5),
          reason: '$mode: onActive on activeFill');
    }
  });

  test('muted text stays legible', () {
    for (final mode in SnipThemeMode.values) {
      final t = SnipTheme.forMode(mode);
      expect(_contrast(t.inkMuted, t.surface), greaterThanOrEqualTo(3.0),
          reason: '$mode: inkMuted on surface');
    }
  });

  test('dark is an inversion, not a tint', () {
    final l = SnipTheme.light();
    final d = SnipTheme.dark();
    expect(_luminance(l.ink), lessThan(_luminance(l.surface)));
    expect(_luminance(d.ink), greaterThan(_luminance(d.surface)));
  });

  test('the theme is monochrome — no chroma in any chrome token', () {
    for (final mode in SnipThemeMode.values) {
      final t = SnipTheme.forMode(mode);
      for (final c in [t.canvas, t.surface, t.surfaceRaised, t.ink,
                       t.inkMuted, t.inkFaint, t.activeFill, t.onActive]) {
        final maxC = math.max(c.r, math.max(c.g, c.b));
        final minC = math.min(c.r, math.min(c.g, c.b));
        expect(maxC - minC, lessThan(0.04),
            reason: '$mode: ${c.toARGB32().toRadixString(16)} is not neutral');
      }
    }
  });

  testWidgets('SnipThemeScope provides and updates', (tester) async {
    late SnipTheme seen;
    Widget app(SnipThemeMode mode) => MaterialApp(
          home: SnipThemeScope(
            theme: SnipTheme.forMode(mode),
            child: Builder(builder: (ctx) {
              seen = SnipTheme.of(ctx);
              return const SizedBox();
            }),
          ),
        );

    await tester.pumpWidget(app(SnipThemeMode.light));
    expect(seen.mode, SnipThemeMode.light);

    await tester.pumpWidget(app(SnipThemeMode.dark));
    expect(seen.mode, SnipThemeMode.dark);
  });
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `flutter test test/snip_theme_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:snipsnap/utils/snip_theme.dart'`.

- [ ] **Step 3: Implement the token layer**

Create `lib/utils/snip_theme.dart`:

```dart
import 'package:flutter/material.dart';

/// The two variants of the skeleton design language.
///
/// Light is ink on paper; dark is its inversion. There is no third mode and no
/// colour identity — chrome is entirely neutral, and the only saturated pixels
/// in the app are the user's own annotations and colour swatches.
enum SnipThemeMode { light, dark }

/// Every chrome colour and metric, resolved for one mode.
///
/// Skeleton removes both colour and fill, which are the two things this app
/// previously used to signal state. Inversion replaces them: an inactive
/// control is a hairline outline, the active one is a solid [activeFill] plate
/// with its icon knocked out in [onActive].
@immutable
class SnipTheme {
  final SnipThemeMode mode;

  /// The workspace behind the capture.
  final Color canvas;

  /// Panels, sidebars, dialogs.
  final Color surface;

  /// A panel sitting on another panel.
  final Color surfaceRaised;

  /// Primary text and iconography.
  final Color ink;

  /// Secondary labels, captions.
  final Color inkMuted;

  /// Dividers and disabled text.
  final Color inkFaint;

  /// The default hairline.
  final Color border;

  /// Hover and emphasis.
  final Color borderStrong;

  /// Fill of the single active control.
  final Color activeFill;

  /// Knocked-out label on [activeFill].
  final Color onActive;

  final double hairline;
  final double activeBorderWidth;
  final double radius;

  const SnipTheme({
    required this.mode,
    required this.canvas,
    required this.surface,
    required this.surfaceRaised,
    required this.ink,
    required this.inkMuted,
    required this.inkFaint,
    required this.border,
    required this.borderStrong,
    required this.activeFill,
    required this.onActive,
    this.hairline = 1.0,
    this.activeBorderWidth = 1.5,
    this.radius = 6.0,
  });

  /// Ink on paper.
  factory SnipTheme.light() => const SnipTheme(
        mode: SnipThemeMode.light,
        canvas: Color(0xFFF2F2F0),
        surface: Color(0xFFFBFBFA),
        surfaceRaised: Color(0xFFFFFFFF),
        ink: Color(0xFF141414),
        inkMuted: Color(0xFF5C5C5C),
        inkFaint: Color(0xFF9A9A9A),
        border: Color(0xFFD8D8D5),
        borderStrong: Color(0xFF141414),
        activeFill: Color(0xFF141414),
        onActive: Color(0xFFFBFBFA),
      );

  /// The inversion. Every role swaps; nothing is tinted.
  factory SnipTheme.dark() => const SnipTheme(
        mode: SnipThemeMode.dark,
        canvas: Color(0xFF0E0E0E),
        surface: Color(0xFF161616),
        surfaceRaised: Color(0xFF1E1E1E),
        ink: Color(0xFFF2F2F0),
        inkMuted: Color(0xFFA0A0A0),
        inkFaint: Color(0xFF6A6A6A),
        border: Color(0xFF343434),
        borderStrong: Color(0xFFF2F2F0),
        activeFill: Color(0xFFF2F2F0),
        onActive: Color(0xFF141414),
      );

  static SnipTheme forMode(SnipThemeMode mode) =>
      mode == SnipThemeMode.dark ? SnipTheme.dark() : SnipTheme.light();

  bool get isDark => mode == SnipThemeMode.dark;

  /// Border for a control in its resting state.
  Border get restingBorder => Border.all(color: border, width: hairline);

  /// Border for a hovered control.
  Border get hoverBorder => Border.all(color: borderStrong, width: hairline);

  /// Reads the theme from the nearest [SnipThemeScope].
  static SnipTheme of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<SnipThemeScope>();
    assert(scope != null, 'No SnipThemeScope found in the widget tree');
    return scope!.theme;
  }

  @override
  bool operator ==(Object other) => other is SnipTheme && other.mode == mode;

  @override
  int get hashCode => mode.hashCode;
}

/// Provides a [SnipTheme] to the subtree.
class SnipThemeScope extends InheritedWidget {
  final SnipTheme theme;

  const SnipThemeScope({
    super.key,
    required this.theme,
    required super.child,
  });

  @override
  bool updateShouldNotify(SnipThemeScope oldWidget) => oldWidget.theme != theme;
}
```

- [ ] **Step 4: Run the tests**

Run: `flutter test test/snip_theme_test.dart`
Expected: PASS (7 tests). If a contrast assertion fails, adjust the token VALUES — never the threshold. The thresholds are the requirement.

- [ ] **Step 5: Verify the whole suite and analyzer**

Run: `flutter test && flutter analyze`
Expected: 207 passing, `No issues found!`

- [ ] **Step 6: Commit**

```bash
git add lib/utils/snip_theme.dart test/snip_theme_test.dart
git commit -m "feat: add the SnipTheme token layer for the skeleton design language"
```

---

## Task 2: Provide the theme, convert `main_screen.dart`

The pilot. Proves the pattern before it is applied 200 more times.

**Files:**
- Modify: `lib/views/main_screen.dart` (19 `isDarkMode` sites, the `MaterialApp` theme, the theme toggle)
- Test: `test/snip_theme_wiring_test.dart` (create)

**Interfaces:**
- Consumes: `SnipTheme`, `SnipThemeScope`, `SnipThemeMode` (Task 1)
- Produces: `SnipThemeScope` wrapping the app; `_MainScreenState._themeMode` → `SnipThemeMode`; children still receive `isDarkMode` until their own task converts them.

- [ ] **Step 1: Wrap the app and derive `ThemeData` from tokens**

In `main_screen.dart`'s `build`, replace the two hand-built `ThemeData` branches with one derived from the token set, and wrap the result in a `SnipThemeScope`:

```dart
    final theme = SnipTheme.forMode(
      _isDarkMode ? SnipThemeMode.dark : SnipThemeMode.light,
    );

    return SnipThemeScope(
      theme: theme,
      child: MaterialApp(
        // ... existing fields ...
        theme: ThemeData(
          useMaterial3: true,
          brightness: theme.isDark ? Brightness.dark : Brightness.light,
          scaffoldBackgroundColor: theme.canvas,
          colorScheme: ColorScheme.fromSeed(
            seedColor: theme.ink,
            brightness: theme.isDark ? Brightness.dark : Brightness.light,
          ).copyWith(
            surface: theme.surface,
            onSurface: theme.ink,
            primary: theme.ink,
            onPrimary: theme.onActive,
          ),
          textTheme: GoogleFonts.interTextTheme(
            theme.isDark ? ThemeData.dark().textTheme : ThemeData.light().textTheme,
          ).apply(bodyColor: theme.ink, displayColor: theme.ink),
          dividerColor: theme.border,
        ),
        // ...
      ),
    );
```

Keep `_isDarkMode` and its persistence exactly as they are — the stored
`theme_mode` values do not change, so no migration is needed.

- [ ] **Step 2: Convert main_screen's own 19 sites**

Apply the mapping table. Every `_isDarkMode ? a : b` inside `main_screen.dart`'s own widgets becomes a token read. `_showToast` (the snackbar colours) is the most visible one:

```dart
  void _showToast(String message) {
    final t = SnipTheme.forMode(
      _isDarkMode ? SnipThemeMode.dark : SnipThemeMode.light,
    );
    // background t.surfaceRaised, text t.ink, border t.border
```

Leave the `isDarkMode:` parameters being PASSED DOWN to child widgets alone — those children are converted in Tasks 3-6 and removing the parameter early breaks them.

- [ ] **Step 3: Write the wiring test**

Create `test/snip_theme_wiring_test.dart`:

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-level invariants. `MainScreen` cannot be pumped — it builds an
/// `EditorCanvas`, which emits `Image.file`, which hangs `flutter_tester`.
String _src(String path) => File(path).readAsStringSync();

void main() {
  test('the app is wrapped in a SnipThemeScope', () {
    final source = _src('lib/views/main_screen.dart');
    expect(source, contains('SnipThemeScope('));
    expect(source, contains('SnipTheme.forMode('));
  });

  test('main_screen no longer hardcodes the violet accent', () {
    final source = _src('lib/views/main_screen.dart');
    expect(
      source,
      isNot(contains('AppColors.accent')),
      reason: 'chrome colour must come from SnipTheme, not AppColors',
    );
  });
}
```

- [ ] **Step 4: Run and verify**

Run: `flutter test && flutter analyze`
Expected: all green, `No issues found!`

- [ ] **Step 5: Commit**

```bash
git add lib/views/main_screen.dart test/snip_theme_wiring_test.dart
git commit -m "feat: provide SnipTheme at the root and convert main_screen"
```

---

## Task 3: `tool_sidebar.dart` and `header_bar.dart`

The two files that define the skeleton look. 52 sites between them, and this is where the inversion treatment is established for every other control to copy.

**Files:**
- Modify: `lib/views/components/tool_sidebar.dart` (13 sites)
- Modify: `lib/views/components/header_bar.dart` (39 sites)
- Test: `test/header_bar_test.dart` (extend — it already pumps the header at several widths)

**Interfaces:**
- Consumes: `SnipTheme.of(context)`
- Produces: the canonical inactive/hover/active treatment other tasks copy.

- [ ] **Step 1: Convert the tool sidebar's selected state to inversion**

Each tool button: at rest a hairline outline with an `inkMuted` label; when `isSelected`, a solid `activeFill` plate with the icon and label in `onActive`. Replace the current accent-tinted background and accent icon colour.

```dart
      decoration: BoxDecoration(
        color: isSelected ? t.activeFill : Colors.transparent,
        borderRadius: BorderRadius.circular(t.radius),
        border: Border.all(
          color: isSelected ? t.activeFill : t.border,
          width: isSelected ? t.activeBorderWidth : t.hairline,
        ),
      ),
```
with icon colour `isSelected ? t.onActive : t.ink` and label `isSelected ? t.onActive : t.inkMuted`.

- [ ] **Step 2: Convert the header bar**

Same treatment for its toggle pills and icon buttons. The zoom stepper, the edit pill, and the capture/export controls all follow the inactive/active rule above. Replace every `AppColors.accent` with `t.ink` (a mark) or `t.activeFill` (a plate) per the mapping table.

- [ ] **Step 3: Keep the existing header tests passing, and add a theme test**

`test/header_bar_test.dart` already pumps `HeaderBar` at several widths and asserts no overflow. It must keep passing. Add one case asserting the header renders in both modes without overflow:

```dart
  for (final dark in [false, true]) {
    testWidgets('lays out without overflow in ${dark ? "dark" : "light"}',
        (tester) async {
      // pump HeaderBar inside a SnipThemeScope for the mode, at 1180px,
      // then: expect(tester.takeException(), isNull);
    });
  }
```

Write the body to match the file's existing pump helper rather than inventing a new one.

- [ ] **Step 4: Verify**

Run: `flutter test && flutter analyze`
Expected: green.

- [ ] **Step 5: Commit**

```bash
git add lib/views/components/tool_sidebar.dart lib/views/components/header_bar.dart test/header_bar_test.dart
git commit -m "feat: skeleton treatment for the tool sidebar and header bar"
```

---

## Task 4: `style_picker.dart`

31 sites, and the one file where real colour must survive.

**Files:**
- Modify: `lib/views/components/style_picker.dart`
- Test: `test/style_picker_slider_range_test.dart` (already exists — must keep passing)

**Interfaces:**
- Consumes: `SnipTheme.of(context)`
- Produces: nothing new.

- [ ] **Step 1: Convert the chrome, preserve the swatches**

Panel background, labels, section headers, slider tracks and thumbs all become tokens. Sliders: hairline track in `t.border`, active portion and thumb in `t.ink`.

**The colour swatches keep their real colours.** `AppColors.palette` is untouched, and each swatch renders its own colour. The SELECTED swatch is marked with a `t.ink` ring rather than an accent-coloured one — the ring is chrome, the fill is data.

- [ ] **Step 2: Verify the slider clamps still hold**

`test/style_picker_slider_range_test.dart` asserts every slider value is clamped into its range. Those clamps must survive the visual conversion untouched.

Run: `flutter test test/style_picker_slider_range_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 3: Verify and commit**

Run: `flutter test && flutter analyze`

```bash
git add lib/views/components/style_picker.dart
git commit -m "feat: skeleton treatment for the style picker, swatches keep real colour"
```

---

## Task 5: `editor_canvas.dart` and `crop_overlay_widget.dart`

29 sites of canvas chrome — selection handles, crop overlay, marquee, the loupe, the empty state.

**Files:**
- Modify: `lib/views/editor_canvas.dart` (26 sites)
- Modify: `lib/views/components/crop_overlay_widget.dart` (3 sites)

**Interfaces:**
- Consumes: `SnipTheme.of(context)`
- Produces: nothing new.

- [ ] **Step 1: Convert canvas chrome only**

Selection handles, the crop dimming and its handles, the marquee, the checkerboard, the delete chip, the loupe frame and the empty state all become tokens.

**Do not touch `AnnotationRenderer` or any annotation colour.** Selection chrome around an annotation is chrome; the annotation itself is data.

The painters (`_CropOverlayPainter`, `_FloatingSelectionPainter`, `_SteadyCheckerboardPainter`, `_LoupeGridPainter`) take `isDarkMode` today. Give each a `SnipTheme` constructor field instead, read from `SnipTheme.of(context)` in `build`, and compare it in `shouldRepaint`.

- [ ] **Step 2: Do not break the frozen signatures**

Run: `grep -n "_emitAnnotation\|_replaceAnnotation\|_canvasAnnotationsFor\|_selectedAnnotation\|hitTestAnnotation" lib/views/editor_canvas.dart`

Confirm all five still read exactly as before. `test/editor_canvas_projection_test.dart` and `test/coordinate_space_guard_test.dart` key on their literal text.

- [ ] **Step 3: Verify and commit**

Run: `flutter test && flutter analyze`
Expected: green, including the source-invariant tests.

```bash
git add lib/views/editor_canvas.dart lib/views/components/crop_overlay_widget.dart
git commit -m "feat: skeleton treatment for canvas chrome"
```

---

## Task 6: Gallery, dialogs, and the OCR panel

53 sites across five files, all pumpable — none of them embeds `Image.file` except the gallery's thumbnails.

**Files:**
- Modify: `lib/views/gallery_sidebar.dart` (14)
- Modify: `lib/views/dialogs/save_as_dialog.dart` (15)
- Modify: `lib/views/dialogs/shortcut_settings_dialog.dart` (12)
- Modify: `lib/views/dialogs/about_dialog.dart` (6)
- Modify: `lib/views/components/ocr_result_panel.dart` (6)
- Test: `test/ocr_result_panel_test.dart` (extend — it already pumps the panel)

**Interfaces:**
- Consumes: `SnipTheme.of(context)`
- Produces: nothing new.

- [ ] **Step 1: Convert all five files**

Apply the mapping table and the state treatment. The gallery's selected-capture indicator uses the inversion rule: selected thumbnail gets an `activeBorderWidth` `t.ink` frame, not an accent tint.

The `save_as_dialog`'s framing-gradient picker keeps its gradient previews in
real colour — same rule as the swatches.

- [ ] **Step 2: Extend the OCR panel test to both modes**

`test/ocr_result_panel_test.dart` already pumps `OcrResultPanel` across its four states. Wrap the existing pump helper in a `SnipThemeScope` and run the state assertions in both modes.

- [ ] **Step 3: Verify and commit**

Run: `flutter test && flutter analyze`

```bash
git add lib/views/gallery_sidebar.dart lib/views/dialogs/ lib/views/components/ocr_result_panel.dart test/ocr_result_panel_test.dart
git commit -m "feat: skeleton treatment for gallery, dialogs and the OCR panel"
```

---

## Task 7: Delete the violet palette and prove it is gone

**Files:**
- Modify: `lib/utils/constants.dart` (remove chrome constants)
- Modify: any file still passing an `isDarkMode` parameter that no longer needs it
- Test: `test/no_chrome_colour_leaks_test.dart` (create)

**Interfaces:**
- Consumes: everything above
- Produces: an executable guarantee that chrome colour cannot come back.

- [ ] **Step 1: Write the guard test first**

Create `test/no_chrome_colour_leaks_test.dart`:

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Files whose chrome must be entirely token-driven.
const _viewFiles = [
  'lib/views/main_screen.dart',
  'lib/views/editor_canvas.dart',
  'lib/views/gallery_sidebar.dart',
  'lib/views/components/tool_sidebar.dart',
  'lib/views/components/header_bar.dart',
  'lib/views/components/style_picker.dart',
  'lib/views/components/ocr_result_panel.dart',
  'lib/views/components/crop_overlay_widget.dart',
  'lib/views/dialogs/save_as_dialog.dart',
  'lib/views/dialogs/shortcut_settings_dialog.dart',
  'lib/views/dialogs/about_dialog.dart',
];

void main() {
  test('no view references a deleted chrome colour', () {
    final offenders = <String>[];
    for (final path in _viewFiles) {
      final source = File(path).readAsStringSync();
      for (final banned in const [
        'AppColors.accent',
        'AppColors.accentHover',
        'AppColors.blueAccent',
        'AppColors.greenAccent',
        'AppColors.darkBg',
        'AppColors.darkSurface',
        'AppColors.lightBg',
        'AppColors.lightSurface',
        'AppColors.sidebarBg',
        'AppColors.canvasBg',
      ]) {
        if (source.contains(banned)) offenders.add('$path → $banned');
      }
    }
    expect(offenders, isEmpty,
        reason: 'chrome colour must come from SnipTheme:\n${offenders.join('\n')}');
  });

  test('no view branches on an isDarkMode boolean', () {
    final offenders = <String>[];
    for (final path in _viewFiles) {
      if (File(path).readAsStringSync().contains('isDarkMode')) {
        offenders.add(path);
      }
    }
    expect(offenders, isEmpty,
        reason: 'state must come from SnipTheme.of(context):\n${offenders.join('\n')}');
  });

  test('annotation colour data survives', () {
    final source = File('lib/utils/constants.dart').readAsStringSync();
    expect(source, contains('palette'),
        reason: 'annotation swatches are data and must not be deleted');
    expect(source, contains('framingGradients'),
        reason: 'export framing gradients are user-selected and must not be deleted');
  });
}
```

- [ ] **Step 2: Run it and see what is left**

Run: `flutter test test/no_chrome_colour_leaks_test.dart`
Expected: FAIL, listing every remaining leak. That list is your work queue.

- [ ] **Step 3: Clear the queue**

Convert every offender the test names. Then delete the now-unreferenced chrome constants from `AppColors` in `lib/utils/constants.dart`, keeping `palette` and `framingGradients`.

Remove `isDarkMode` parameters from widget constructors once no caller passes them. Update every call site in the same commit.

- [ ] **Step 4: Run everything**

Run: `flutter test && flutter analyze`
Expected: all green, `No issues found!`, and the guard test passing.

- [ ] **Step 5: Commit**

```bash
git add lib/ test/
git commit -m "feat: delete the violet chrome palette, guarded by a leak test"
```

---

# Self-Review Notes

**Spec coverage.** Spec §3.1 (token layer) → Task 1. §3.2 (state without colour) → Tasks 3-6, canonical treatment established in Task 3. §3.3 (what stays in colour) → Tasks 4, 6, and the Task 7 guard test. §3.4 (typography) → Task 2's `ThemeData`. §3.5 (persistence unchanged) → Task 2 Step 1. §3.6 (what is deleted) → Task 7.

**Known limitation.** `MainScreen` and `EditorCanvas` cannot be pumped, because `flutter_tester` hangs on any tree containing `Image.file`. Their conversion is verified by source-level invariants and by the analyzer, not at runtime. Every other converted widget IS pumpable and is tested in both modes. The whole-branch check is a human launching the app and looking at it — which is also the only way to judge whether the skeleton language actually reads well.

**Sequencing.** Task 1 has no consumers; Task 2 proves the pattern on the smallest real file; Tasks 3-6 are independent of each other and could run in any order; Task 7 can only run last, because its guard test fails until every other task has landed.
