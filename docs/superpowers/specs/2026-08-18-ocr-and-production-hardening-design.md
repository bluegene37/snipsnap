# SnipSnap: Text Extraction (OCR) + Production Hardening

**Date:** 2026-08-18
**Status:** Draft for review

## Summary

Three pieces of work: add a text-extraction (OCR) tool built on the OCR engines
already in macOS and Windows; fix the correctness and platform defects that
block a production release; and add a monochrome "skeleton" theme as a third
mode alongside dark and light.

The order is not arbitrary. OCR needs to map a canvas drag rectangle to native
image pixels, and that mapping is currently broken — so the coordinate rework
lands first. The theme needs a token layer that does not exist yet, and that
refactor touches nearly every view file — so it lands last, after the
behavioral work is stable.

## Goals

- Extract text from a capture — whole image or a dragged region — on macOS and
  Windows, offline, with no bundled binaries and no user setup.
- Word-level bounding boxes so text can be selected on-canvas, not just dumped.
- Fix the defects that make the app unsafe to ship: coordinate drift, silent
  annotation loss on export, broken Linux clipboard, unbounded temp files and
  undo memory.
- Replace 212 hardcoded theme branches with a token layer, and ship a
  monochrome skeleton mode on top of it.
- Leave a seam for Linux OCR without designing for it now.

## Non-Goals

- Linux OCR. No OS-provided engine exists; bundling Tesseract is a packaging
  project, not a code project. Linux shows an explicit unavailable state.
- Handwriting recognition, PDF export, translation, cloud engines.
- Rewriting `EditorCanvas` wholesale. Targeted extraction only, where it serves
  this work.
- Restyling annotations. Skeleton changes app chrome only; markup stays in full
  color.

---

# Part 1 — OCR

## 1.1 Engine strategy

| Platform | Engine | Bundle | Setup | Min OS |
|---|---|---|---|---|
| macOS | Vision `VNRecognizeTextRequest` | 0 MB | none | 12.0 (already the target) |
| Windows | `Windows.Media.Ocr` | 0 MB | none | Windows 10 |
| Linux | none — explicit unavailable state | — | — | — |

Both engines are offline, free, ship with the OS, and return per-word bounding
boxes. Neither requires a new entitlement; Vision works inside the existing
app sandbox.

**Known degradations, handled explicitly:**

- macOS 12 gets Vision revision 2 (revision 3 needs macOS 13). Select the
  newest supported revision at runtime rather than pinning.
- `OcrEngine.TryCreateFromUserProfileLanguages()` returns null when no OCR
  language pack is installed. Fall back to
  `AvailableRecognizerLanguages.first`, and surface an actionable message if
  that is empty too.

## 1.2 Dart architecture

```
lib/services/ocr/
  ocr_engine.dart              # abstract OcrEngine; OcrResult / OcrLine / OcrWord
  ocr_service.dart             # host-platform engine selection + per-capture cache
  vision_ocr_engine.dart       # macOS   — MethodChannel('snipsnap/ocr')
  windows_ocr_engine.dart      # Windows — same channel, WinRT implementation
  unavailable_ocr_engine.dart  # Linux and unsupported OS versions
```

```dart
abstract class OcrEngine {
  Future<OcrAvailability> availability();
  Future<OcrResult> recognize(Uint8List pngBytes);
}
```

One channel name, two native implementations, one Dart interface. `OcrService`
picks the engine once and caches per `(captureId, imageRevision)` so edits
invalidate results but idle re-opens do not re-run recognition.

**Coordinate contract:** `OcrResult` boxes are in **native image pixels**,
never canvas coordinates. This is the same contract Part 2 establishes for
annotations, so both use one conversion path.

```dart
class OcrWord   { final String text; final Rect boundsPx; final double confidence; }
class OcrLine   { final String text; final Rect boundsPx; final List<OcrWord> words; }
class OcrResult { final List<OcrLine> lines; final String plainText; final Size imageSize; }
```

Vision returns normalized boxes with a bottom-left origin; the Swift side flips
to top-left and scales to pixels so Dart never sees two conventions.

## 1.3 Native surface

- `macos/Runner/OcrPlugin.swift` — registered from `MainFlutterWindow.swift`.
- `windows/runner/ocr_handler.cpp` — registered from `flutter_window.cpp`;
  requires `windowsapp.lib` in `windows/runner/CMakeLists.txt` and
  `winrt::init_apartment()`.

Both runners are currently stock, so all native work is additive. Linux needs
no build change.

Method channel `snipsnap/ocr`:

| Method | Args | Returns |
|---|---|---|
| `availability` | — | `{available: bool, reason: String?, languages: [String]}` |
| `recognize` | `{png: Uint8List}` | `{lines: [{text, x, y, w, h, confidence, words: [...]}], width, height}` |

The region crop happens in Dart before the call, so natives receive a plain PNG
and stay free of coordinate logic.

## 1.4 Tool behavior

`CanvasTool.ocr`, shortcut `E` (extract), placed next to the eyedropper.

- **Drag a region** → OCR those pixels → floating result panel.
- **Click, no drag** → OCR the whole capture.
- **Recognized words render as selectable overlays**, so a partial selection is
  possible without re-running recognition.
- **Panel actions:** Copy all, copy selection, insert as a text annotation.
- **Low-confidence words render dimmed** rather than being silently dropped.
- **Unavailable platform:** the tool is visible but disabled, with a tooltip
  stating why. It is never silently missing.

Recognition runs off the UI thread on both natives. The panel shows an
indeterminate spinner while a request is in flight — 4K captures routinely
exceed 150 ms, which is long enough to need feedback.

## 1.5 Error handling

| Condition | Behavior |
|---|---|
| Engine unavailable | Tool disabled, tooltip explains, no crash path |
| No language pack (Windows) | Actionable message naming the Settings page |
| Recognition returns nothing | "No text found" empty state, not an error toast |
| Native throws | Caught at the channel boundary, surfaced as a toast, logged |
| Region smaller than 8×8 px | Ignored, no call issued |

---

# Part 2 — Production Hardening

## 2.1 Coordinate normalization (prerequisite)

**Problem.** Annotations are stored in canvas viewport coordinates taken from
`details.localPosition`, while the image's position inside that canvas is
computed live from the widget's current size. The mapping is therefore a
function of window layout at draw time. Resizing the window, toggling a panel,
or reopening a capture at a different window size makes markup drift off its
target. Persisted rows are only valid for the viewport that produced them.

**Fix.** Store geometry in native image pixels. Convert at the gesture boundary
on input and back to canvas coordinates for painting. `RenderService.imageRectInCanvas`
already provides the transform, and `_canvasPointToImagePixel`
(`editor_canvas.dart:1281`) is most of the inbound half.

**Three defects close together:**

1. Annotation drift on resize (above).
2. **Ruler reports wrong measurements.** `annotation_renderer.dart:725` computes
   length from canvas coordinates and labels the result `px`. A 3840px-wide
   screenshot displayed in a 900px canvas under-reports by roughly 4×. A
   measuring tool that measures the wrong thing is a correctness bug, and this
   change fixes it inherently.
3. OCR region selection needs exactly this mapping to be correct.

**Migration.** Existing persisted annotations are in viewport coordinates with
no record of the viewport that produced them, so they cannot be converted
exactly. Bump the Drift schema to v4 and add a `coordSpace` column defaulting to
`viewport` for existing rows; new rows write `imagePixels`.

At load, `viewport` rows are converted once using the capture's stored
dimensions fitted to the *current* canvas, then rewritten as `imagePixels`. This
is correct when the window is the size it was at draw time and approximate
otherwise — the same accuracy those rows already have today, with the drift
frozen rather than recurring on every subsequent resize. Captures with zero
stored dimensions (rows created before width/height were populated) are decoded
once to recover them.

## 2.2 Silent annotation loss on export

`main_screen.dart:641` returns `Size.zero` when the canvas is not laid out,
while `editor_canvas.dart:347` returns `Size(800, 600)` for the same concept.
With `Size.zero`, `render_service.dart:83` takes the `imageRect.isEmpty` branch
and returns the original bytes **with annotations dropped** — the export
reports success and the markup is gone. `_handleApplyCrop` aborts silently in
the same situation.

**Fix.** One shared canvas-size source. Both paths fail loudly rather than
degrading to a wrong-but-successful result.

## 2.3 Resolve `lib/tools/`

Fourteen handler classes implementing the `ToolHandler` strategy that
`GEMINI.md` §1.1 mandates are unreachable — nothing outside `lib/tools/`
imports them. `EditorCanvas` re-implements all of it inline. The only consumer
is `test/tool_handlers_test.dart`, so 16 tests validate code the app never runs,
and the two copies have already drifted.

**Fix.** Wire the handlers into `EditorCanvas` and add OCR as a proper
`ToolHandler`. This matches the documented architecture, makes the existing
tests meaningful, and starts reducing a 2,724-line widget that currently has no
direct test coverage.

## 2.4 Platform and resource defects

| Defect | Location | Fix |
|---|---|---|
| Wayland clipboard broken — `<` passed as a literal argument, no shell, no redirection | `clipboard_service.dart:22` | `wl-copy --type image/png` with bytes on stdin |
| Windows capture uses deprecated `snippingtool /clip` plus a 600 ms clipboard race | `capture_service.dart:45` | Replace; user has 0.6s to complete a snip today |
| Temp files never cleaned — every clipboard copy leaves a rendered screenshot in a fresh temp dir | `storage_service.dart:138` | Reuse one dir, sweep on launch |
| Undo stack bounded by step count, not bytes — 80 full-resolution PNGs | `main_screen.dart` | Byte budget |
| `copyWith` cannot clear `startPoint`/`endPoint`/`rect`; two call sites pass `null` expecting a clear and silently no-op | `annotation.dart`, `editor_canvas.dart:1204,1272` | Extend the `_unset` sentinel |
| Failing test asserts a mathematically wrong snap — 8.53° correctly rounds to 15°, test expects 0 | `tool_handlers_test.dart:194` | Use a sub-7.5° drag |
| Script injection — paths interpolated into PowerShell/AppleScript with only `"` escaped | capture/clipboard/storage services | Argument-list invocation |

## 2.5 Flagged, decided separately

The app is sandboxed (`com.apple.security.app-sandbox`) while shelling out to
`/usr/sbin/screencapture`. This works in development but is the most likely
thing to break under notarization and distribution. It needs its own decision —
ScreenCaptureKit, or dropping the sandbox — and is out of scope here.

---

# Part 3 — Skeleton Theme

## 3.1 The blocker: there is no theming layer

`AppColors` is a set of static constants and widgets branch on an `isDarkMode`
boolean — **212 occurrences across 10 files**. `ThemeData` is declared at
`main_screen.dart:884` but almost nothing reads `Theme.of(context)`.

That is a two-valued switch. A third mode cannot be added by extending it; 212
three-way ternaries is not maintainable. The boolean must become a token object
first.

```dart
enum SnipThemeMode { dark, light, skeleton }

class SnipTheme {
  final Color canvas, surface, surfaceRaised, ink, inkMuted, inkFaint;
  final Color border, borderStrong, activeFill, onActive;
  final double borderWidth, activeBorderWidth, radius;
  final bool usesFills;
  final TextTheme text;
}
```

Provided via `InheritedWidget` and read as `SnipTheme.of(context)`. Every
`isDarkMode ? a : b` becomes a token reference. This is mechanical but broad —
it is the single largest diff in the plan, and it is a prerequisite for the
theme, not optional groundwork.

## 3.2 State without color

Skeleton removes both color and fill, which are the two things the app
currently uses to show state — and this app carries a lot of it: active tool,
8 shape kinds, filled-vs-hollow, dashed-vs-solid, a dozen sliders. Inversion
does that work instead.

| State | Treatment |
|---|---|
| Inactive | 1px hairline border, muted label, no fill |
| Hover | Border darkens to `borderStrong`; no fill, no movement |
| **Active / selected** | **Solid black fill, icon and label knocked out in white** |
| Disabled | Dashed hairline, label at 40% |
| Focused | 1px offset outer ring |

The inversion is the whole system, applied uniformly:

- **Tool buttons** — outline at rest, solid black plate when selected.
- **Toggles** — hairline pill, solid black knob; the knob's position and fill
  both carry the state.
- **Sliders** — hairline track, solid black thumb; filled portion of the track
  is a 2px black rule against a 1px gray one.
- **Canvas** — dashed hairline boundary so the image reads as a mounted plate.
- **Panels** — separated by hairlines only. No elevation, no shadow, no fills.

**One deliberate exception:** color swatches and the active-color indicator
render in real color. They are data, not chrome — a monochrome color picker is
a broken color picker.

## 3.3 What stays in color

Annotations are unaffected. Red arrows and yellow highlighter are the product;
only the chrome around the canvas goes monochrome. `AppColors.palette` and
`framingGradients` are untouched by this work.

## 3.4 Typography

Skeleton lives or dies on type, since there is no color doing hierarchy. One
family, four sizes, two weights (400/500). Weight and spacing carry hierarchy
rather than color or size jumps. `google_fonts` stays, restricted to a single
family so the app stops mixing defaults.

## 3.5 Persistence

The stored `theme_mode` setting is currently `'dark' | 'light'`. It becomes a
three-value enum; unrecognized values fall back to `dark` so existing installs
are unaffected. The header's theme control becomes a three-way cycle rather
than a toggle.

---

# Sequencing

**Phase 1 — Coordinate correctness.** Normalization, schema v4 migration, ruler
fix, `Size.zero` fix. Prerequisite for everything else.

**Phase 2 — Tool layer.** Wire `lib/tools/` in, fix the failing test, extend the
`copyWith` sentinel.

**Phase 3 — OCR.** Dart interface and service, then macOS Vision, then Windows
WinRT, then the tool and result panel.

**Phase 4 — Platform and resource fixes.** Section 2.4 remainder.

**Phase 5 — Theming.** Token layer replacing 212 boolean branches, then the
skeleton mode and the three-way theme setting. Sequenced last deliberately: it
touches nearly every view file, so running it after the functional work avoids
rebasing behavioral changes across a large cosmetic diff. The OCR result panel
(Phase 3) is built against tokens from the start so it needs no rework.

Each phase is independently shippable and leaves the app in a working state.

# Testing

- **Coordinate round-trips** — property tests across several viewport sizes and
  aspect ratios. This is the regression net for §2.1 and the highest-value
  tests in the plan.
- **Ruler measurement** — asserts image pixels, not display pixels.
- **OCR service** — `OcrEngine` is an interface, so the service, caching,
  invalidation, and region cropping are testable with a fake and no native code.
- **Result mapping** — fixtures of real native payloads, asserting the
  bottom-left-to-top-left flip and pixel scaling.
- **Export** — extends `render_service_test.dart` to cover the `Size.zero` path
  failing loudly.
- **Native paths** — one manual smoke test per platform; not automatable in CI
  without both hosts.
- **Theme tokens** — a test asserting every `SnipThemeMode` resolves a complete
  token set, so a mode can never ship with a null color. `header_bar_test.dart`
  already renders across widths; extend it across all three modes.
- **Contrast** — assert the ink-on-surface and knocked-out-on-active pairs meet
  WCAG AA. Skeleton has no color to fall back on, so contrast is the only thing
  keeping it legible.

# Risks

| Risk | Mitigation |
|---|---|
| Legacy annotations cannot be converted exactly | Best-effort with a `coordSpace` discriminator; accept approximation for old rows |
| Windows WinRT from a Win32 Flutter runner | `Windows.Media.Ocr` is supported in desktop apps; validate early in Phase 3 |
| Wiring `lib/tools/` in regresses gesture behavior | The two implementations have drifted; diff them explicitly rather than assuming equivalence |
| No Windows machine available for testing | Windows OCR and capture fixes need a real host or VM; flag before Phase 3 starts |
| Skeleton hurts state legibility — no color or fill to signal active | Inversion (§3.2) is the state system, applied uniformly, with AA contrast tests. This was raised as a concern and the direction was chosen deliberately; if it reads poorly in practice the fix is a heavier active treatment, not adding color back |
| The 212-branch token refactor is a large mechanical diff | Sequenced last, landed as its own phase, mode-completeness tests as the net |
