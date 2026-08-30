# QA Report — SnipSnap (macOS desktop)

- **Date:** 2026-08-30
- **Branch:** `main` (started at `d4ca24f`)
- **Tier:** Standard (fix critical + high + medium; report low/cosmetic)
- **Scope:** Live app on macOS + `flutter analyze` + full test suite
- **Method:** Debug build driven on the real macOS window (synthetic mouse/keyboard),
  screenshot evidence per step, Dart VM service watched for runtime errors throughout.

**Health score: 71 → 100.** Three issues found, three fixed and verified.

> Scoring: start at 100, −15 per high, −7 per medium, −2 per cosmetic.
> Baseline 100 − 15 (ISSUE-002) − 7 − 7 (ISSUE-001, ISSUE-003) = 71.

**PR summary:** QA found 3 issues, fixed 3, health score 71 → 100.

---

## Baseline

| Check | Result |
|---|---|
| `flutter analyze` | 0 issues |
| `flutter test` | 548 passed |
| Runtime errors during the whole session | none |

---

## Issues

### ISSUE-002 — the in-app manual documents shortcuts that do not exist (high)

**Fix status:** verified · **Commit:** `452bfcc` · **Files:** `lib/views/dialogs/user_manual_data.dart`

The User Manual added in `d4ca24f` was written from an imagined spec rather than the
real bindings. Nine claims were wrong, and three of them are actively harmful:

| Manual said | Actually | Consequence |
|---|---|---|
| Area Snip `Cmd+Shift+4` | `Cmd+Shift+1` | Fires **Apple's** area screenshot |
| Full Screen Snip `Cmd+Shift+3` | `Cmd+Shift+2` | Fires **Apple's** full screenshot |
| 3s Timer Snip `Cmd+Shift+5` | `Cmd+Shift+6` | Fires **Apple's** screenshot UI |
| Step Marker `S` | `N` (or `1`) | `S` selects the **Select** tool |
| OCR `C` | `E` | `C` selects the **Crop** tool |
| Fill `G`… documented as `F` | `G` | `F` is unmapped, nothing happens |
| Ovals `O` | Shape is `R` / `U` | `O` is unmapped |
| Paste from clipboard `Cmd+V` | not implemented | no paste path exists |
| Tool Properties `Cmd+P` | not bound | nothing happens |

The capture chords are the worst of it, and the codebase already knew:
`shortcut_service.dart:27` carries a comment explaining that `Cmd+Shift+3/4/5`
are the macOS system chords and that digit 6 was chosen because it is free.
The manual then told users to press exactly those three.

**Repro:** open the manual (F1) → Keyboard Shortcuts topic → read the global
capture hotkeys → press any of them. macOS captures instead of SnipSnap.

**Evidence:** `screenshots/issue-002-before-manual.png`,
`screenshots/issue-002-before-shortcuts-dialog.png` (the real defaults, `Control ⇧ X`
customised from `Cmd+Shift+1`).

**Fix:** corrected every claim against `shortcut_service.dart` defaults and the
`toolKeys` map in `editor_canvas.dart`; dropped the two unimplemented ones; also
corrected the zoom range (20 %, not 25 %) and the "100 % = 1:1 pixels" wording
(100 % is the fit-to-window baseline). Added the missing `Cmd+Shift+K`.

**Regression test:** `test/views/dialogs/user_manual_shortcuts_regression_test.dart`
(commit `783ceb6`) — pins every chord claim against `ShortcutService.getDefaultShortcuts()`
and every bare letter against the canvas tool-key contract, so the doc cannot drift
silently again. Fails 4 of 7 cases on the pre-fix data.

---

### ISSUE-001 — manual search desyncs the sidebar highlight from the content (medium)

**Fix status:** verified · **Commit:** `227e983` · **Files:** `lib/views/dialogs/user_manual_dialog.dart`

The content pane renders `_activeTopic`, which falls back to the first search match;
the sidebar highlights `_selectedTopicId`, which still pointed at the filtered-out
topic. Two visible symptoms:

1. A topic is on screen with **no sidebar row highlighted** — the reader cannot tell
   what they are looking at.
2. Clearing the search **discards** what they were reading and jumps back to the old
   topic.

**Repro:** F1 with the Text tool active (opens on "Annotation & Drawing Tools") →
type `ocr` → pane shows "Getting Started", nothing highlighted → clear the search →
snaps back to "Annotation & Drawing Tools".

**Evidence:** before `screenshots/issue-001-before.png` (no row highlighted),
after `screenshots/issue-001-after.png` ("Getting Started" highlighted).

**Fix:** when a search filters the current selection out, promote the fallback to the
real selection, so the two states cannot diverge. An empty result set leaves the
selection alone, so clearing a no-match query still restores it.

**Regression test:** `test/views/dialogs/user_manual_search_selection_regression_test.dart`
(commit `665732b`). Fails 2 of 3 cases on the pre-fix dialog.

---

### ISSUE-003 — transparency checkerboard strands itself when the canvas resizes (medium)

**Fix status:** verified · **Commit:** `8fd4516` · **Files:** `lib/views/editor_canvas.dart`

The checkerboard under the capture was positioned from `_imageRect`, which measures
the RepaintBoundary's render box and therefore reports the *previous* layout. On the
frame a viewport resize lands, it keeps the old geometry while `RawImage` re-fits to
the new one — and nothing schedules a second build to correct it, so it stays wrong.
A transparent band appears above the screenshot until the user clicks Fit.

**Repro:** open a capture → press `Cmd+H` to hide the gallery strip → a checkerboard
band sits above the image. Also reachable by resizing the window or collapsing the
properties panel.

**Evidence:** before `screenshots/issue-003-before.png`, after
`screenshots/issue-003-after.png`. Measured intra-row pixel spread across the band
dropped from 17 (checkerboard alternation) to 6 (uniform backdrop).

**Fix:** size the layer from live constraints via `LayoutBuilder` — the same way the
annotation layer in that same Stack already avoids the stale render box.

**Regression test:** `test/canvas_checkerboard_resize_regression_test.dart`
(commit `68c2051`). Fails both resize directions on the pre-fix canvas.

---

## Checked and clean

Worth recording, because several of these looked broken at first and were not:

| Area | Result |
|---|---|
| `Cmd+Z` / `Cmd+Shift+Z` / `Cmd+C` / `Cmd+O` / `Cmd+H` | all work. An early "these are dead" reading was my synthetic-input harness dropping the modifier, not the app. The stock `MainMenu.xib` Edit menu claims `⌘Z/⌘C/⌘V/⌘X/⌘A` but its items are inert, so the keys reach Flutter. |
| Update checker | Manual check works end to end against the live GitHub API; shows "SnipSnap 1.0.0 is up to date." `screenshots/update-check-uptodate.png` |
| Dark mode | Clean across header, tool rail, properties panel and gallery — no light leaks, no stock-M3 purple. `screenshots/dark-mode.png` |
| Manual: empty-search state | Correct on both panes ("No matching topics" / "No matching guides found") |
| Manual: context-aware opening | F1 opens the topic matching the active tool. Intentional, works. |
| Manual → Keyboard Shortcuts footer button | Replaces the dialog rather than stacking. Correct. |
| Dialog layout at minimum window size (960×640) | The 860×640 manual is clamped by `Dialog`; no overflow. |
| Save As dialog | Renders correctly, PNG/JPEG + framing options present. |
| Tool sidebar / properties panel | All tools select; panel scrolls; per-tool properties correct. |
| Canvas | Draw, select, resize handles, delete badge, undo/redo via toolbar all correct. |
| Zoom | Header stepper, slider and fit button behave; 20 %–400 % clamp matches the code. |
| macOS bundle id | `dev.genexis.snipsnap` — correct. (A stale `com.example.snipsnap` container from older builds exists on this machine but is not what ships.) |
| Runtime errors | None, across the entire session. |

---

## Deferred

- **Pan transform is not re-clamped on viewport resize** (low, unproven).
  `_constrain` clamps translation against the viewport as it stood when the transform
  was last written. Shrinking the viewport while zoomed in narrows the valid range, so
  a previously valid translation can fall outside it. I wrote the re-clamp, could not
  produce an observable defect from it, and removed it rather than ship an unverified
  behaviour change to the canvas transform. Worth a targeted test if anyone sees the
  view sitting off its own edge after a resize.
- **`Cmd+H` collides with the macOS Hide App convention.** SnipSnap wins the key here,
  so the gallery toggle works — but macOS users reaching for Hide get a sidebar toggle.
  Product call, not a defect.
- **Snip / capture flows and OCR extraction were not exercised** — both take over the
  screen or need the Screen Recording prompt, and this session was driving the machine
  the user was on. Everything downstream of a capture was tested against the existing
  one.

---

## Verification

| Check | After fixes |
|---|---|
| `flutter analyze` | 0 issues |
| `flutter test` | 561 passed (548 baseline + 13 new regression tests) |
| Each fix re-tested in the live app | yes, with before/after screenshots |
| Each regression test confirmed to fail without its fix | yes |
