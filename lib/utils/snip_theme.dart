import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The two variants of the skeleton design language.
///
/// Light is ink on paper; dark is its inversion. There is no third mode and
/// almost no colour identity: chrome is neutral, and the user's own
/// annotations and colour swatches remain the app's primary saturated
/// pixels. The one deliberate exception is [SnipTheme.danger] /
/// [SnipTheme.onDanger] — see their doc comments for why red survives.
enum SnipThemeMode { light, dark }

/// Every chrome colour and metric, resolved for one mode.
///
/// Skeleton removes both colour and fill, which are the two things this app
/// previously used to signal state. Inversion replaces them: an inactive
/// control is a hairline outline, the active one is a solid [activeFill] plate
/// with its icon knocked out in [onActive].
///
/// Five chrome needs beyond the active/inactive binary have sanctioned
/// tokens rather than being left for each call site to invent:
///
/// * **Selected, not exclusive** — [selectedFill] is for multi-select or
///   non-exclusive controls (a `ChoiceChip`, a selected card in a grid)
///   where [activeFill] would wrongly claim the single-active-control
///   exclusivity it signals elsewhere. Its foreground is the ordinary [ink]
///   token, not [onActive]: nothing is knocked out, this is a highlight,
///   not an inversion.
/// * **Hover as a fill** — [hoverFill] is for a translucent hover wash on
///   rows and tiles that have no border to strengthen (list rows, icon
///   buttons). [borderStrong] remains the hover treatment for anything
///   that already has a hairline. Foreground stays [ink]/[inkMuted].
/// * **Call-to-action emphasis** — [emphasis] is for a control that wants
///   more visual weight than a resting hairline (a pill nudging the user to
///   reopen a collapsed panel, a header CTA) but is *not* the app's one
///   exclusive active control — [activeFill] stays reserved for that.
///   Skeleton has no colour to spend on emphasis, so [emphasis] borrows
///   [ink]'s strength for a border/icon/text instead of introducing a tint.
///   **It is a CTA-border/text token, not a state differentiator**:
///   [emphasis] is defined equal to [ink] in both modes (see the fields
///   below), so a branch like `isX ? ink : emphasis` renders both arms
///   identically and communicates nothing. Any control that needs to show
///   "this differs from some other state" must signal it by weight, border,
///   fill, or glyph — never by reaching for [emphasis] as if it were a
///   second, distinguishable hue.
/// * **Destructive** — [danger] and [onDanger] are the one sanctioned
///   chromatic exception to the monochrome rule. Deleting a capture is
///   irreversible, and the safety affordance of a red warning outweighs
///   monochrome purity; naming it a token keeps the exception greppable
///   and singular instead of every call site picking its own red.
/// * **Scrim** — [SnipTheme.scrim] dims live content behind a modal-style
///   overlay (the moment between triggering an OS-level capture and it
///   landing). It is the one token that is deliberately *not* per-mode: a
///   scrim's job is to darken whatever is behind it regardless of chrome
///   mode, so it is a single `static const`, not a light/dark pair. See its
///   own doc comment for why per-mode would actively be wrong here.
///
/// [SnipTheme.controlDecoration]/[SnipTheme.controlForeground] cover five
/// more combinations beyond the plain active/inactive binary — disabled
/// (including a disabled *selected* control), a hovered control (bordered
/// or not), and a destructive-toned control — so no call site ever hand-rolls
/// a `BoxDecoration` ternary for these. See their own doc comments.
enum SnipControlTone {
  /// The ordinary monochrome treatment — everything except delete affordances.
  neutral,

  /// The one sanctioned chromatic exception. Routes through [SnipTheme.danger]
  /// / [SnipTheme.onDanger] instead of [SnipTheme.activeFill] / [SnipTheme.onActive].
  danger,
}

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

  /// Fill for a selected-but-not-exclusive control (a chosen chip, a
  /// selected card in a multi-select grid). Distinct from [activeFill],
  /// which signals the single exclusive active control. Foreground is the
  /// ordinary [ink] token — this is a highlight, not an inversion.
  final Color selectedFill;

  /// Translucent-style hover wash for rows and tiles that have no border
  /// to strengthen. For anything with a hairline, prefer [borderStrong] as
  /// the hover treatment instead.
  final Color hoverFill;

  /// The one sanctioned chromatic exception to the monochrome rule:
  /// destructive / irreversible affordances (delete). Never use an inline
  /// red — this token is the single, greppable place that colour lives.
  final Color danger;

  /// Knocked-out label on [danger], mirroring [onActive]'s role for the
  /// active plate.
  final Color onDanger;

  /// Border/icon/text strength for a call-to-action that wants more weight
  /// than a resting hairline but is not the app's one exclusive active
  /// control (that stays [activeFill]). Same value as [ink] in both modes —
  /// named separately so header/toolbar call sites converge on one
  /// convention instead of each reinventing "strong ink border" ad hoc.
  final Color emphasis;

  final double hairline;
  final double activeBorderWidth;
  final double radius;

  /// The one sanctioned translucent scrim, for a full-bleed dim over live
  /// content. Deliberately mode-invariant, unlike every other token: a
  /// scrim's job is to darken whatever is behind it regardless of chrome
  /// mode. Tokenising it per-mode (e.g. to [ink] with alpha) would flip its
  /// polarity in dark mode — [ink] is near-white there, so it would wash the
  /// screen *lighter* mid-capture instead of dimming it, and risk whatever
  /// foreground content sits on top of it (a spinner, a caption) becoming
  /// illegible. Equal to the pre-conversion `Colors.black54` literal.
  static const Color scrim = Color(0x8A000000);

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
    required this.selectedFill,
    required this.hoverFill,
    required this.danger,
    required this.onDanger,
    required this.emphasis,
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
    selectedFill: Color(0xFFE8E8E8),
    hoverFill: Color(0xFFEDEDED),
    danger: Color(0xFFB3261E),
    onDanger: Color(0xFFFBFBFA),
    emphasis: Color(0xFF141414),
  );

  /// The inversion. Every role swaps; nothing is tinted.
  ///
  /// [ink] here (`0xFFF2F2F0`) is not perfectly neutral — R/G are 242, B is
  /// 240, a 2-unit deficit — and that is deliberate, not an oversight: it is
  /// the exact same hex as [SnipTheme.light]'s [canvas]. The two paper tones
  /// this design uses, `0xFF141414` (near-black) and `0xFFF2F2F0` (near-white
  /// with a hair of warmth), each appear on both sides of the inversion —
  /// `0xFF141414` is light's [ink] *and* dark's [onActive]/[onDanger];
  /// `0xFFF2F2F0` is light's [canvas] *and* dark's [ink] — so "paper" and
  /// "mark" are always the same two physical colours with their roles
  /// swapped, never two different colour identities. Snapping dark's [ink]
  /// to a fully neutral grey would be flatter but would break that identity.
  /// `test/snip_theme_test.dart`'s "dark ink reuses light's paper tone"
  /// case pins this so a future "cleanup" doesn't quietly undo it.
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
    selectedFill: Color(0xFF2A2A2A),
    hoverFill: Color(0xFF202020),
    danger: Color(0xFFFF6B6B),
    onDanger: Color(0xFF141414),
    emphasis: Color(0xFFF2F2F0),
  );

  static SnipTheme forMode(SnipThemeMode mode) =>
      mode == SnipThemeMode.dark ? SnipTheme.dark() : SnipTheme.light();

  bool get isDark => mode == SnipThemeMode.dark;

  /// Border for a control in its resting state.
  Border get restingBorder => Border.all(color: border, width: hairline);

  /// Border for a hovered control.
  Border get hoverBorder => Border.all(color: borderStrong, width: hairline);

  /// The outline/fill for a control, covering every combination this design
  /// distinguishes:
  ///
  /// * **resting** (`active: false`, `enabled: true`, no hover): hairline
  ///   [border], no fill.
  /// * **hovered** (`hover: true`): if [bordered] (the default), the
  ///   hairline strengthens to [borderStrong] — for a control that already
  ///   carries a border. If `bordered: false` — a list row or tile with no
  ///   border to strengthen — the border stays absent and [hoverFill] washes
  ///   the fill instead.
  /// * **non-exclusive selected** (`active: true, exclusive: false`, the
  ///   default is exclusive so pass this explicitly): [selectedFill] with a
  ///   matching hairline — a highlight, not a knockout, for a control that
  ///   can be "on" alongside some other control.
  /// * **exclusive active** (`active: true, exclusive: true`, the default):
  ///   [activeFill] plate, border matching at [activeBorderWidth] — reserved
  ///   for a control that is the single active member of its own group
  ///   (meant to be knocked out via [controlForeground]).
  /// * **disabled** (`enabled: false`): never renders the loud knockout
  ///   plate, active or not — an exclusive-active *and disabled* control
  ///   downgrades to the quieter [selectedFill] highlight shape rather than
  ///   [activeFill], since a full-strength inverted plate reads as
  ///   interactive. A disabled resting control is unaffected: still a plain
  ///   hairline. Hover is ignored entirely once disabled. Pair with
  ///   [controlForeground]'s own `enabled: false`, which always answers
  ///   [inkFaint] regardless of the fill drawn here.
  /// * **destructive** (`tone: SnipControlTone.danger`): the same
  ///   resting/hovered/active shape, but every colour that would have been
  ///   [border]/[borderStrong] is [danger] instead. For **exclusive-active**
  ///   the fill itself swaps too ([activeFill] → [danger]) — the one
  ///   sanctioned chromatic exception. For **non-exclusive selected** the
  ///   fill stays [selectedFill] (only the outline becomes [danger]):
  ///   [controlForeground] answers plain [danger] text there, not the
  ///   [onDanger] knockout, precisely because [selectedFill] is never
  ///   replaced — see [controlForeground]'s own doc comment for why the two
  ///   must branch on `exclusive` before `tone` to stay paired.
  ///
  /// [radius] defaults to the [radius] field; pass an explicit value to
  /// match a control's own corner radius.
  ///
  /// This exists so the same shape doesn't get hand-duplicated — and
  /// occasionally gotten subtly wrong (the resting border in particular) —
  /// at every call site. [controlForeground] is its foreground-colour
  /// companion; use them together so a control's icon and label can never
  /// drift out of sync with its own fill.
  BoxDecoration controlDecoration({
    required bool active,
    bool exclusive = true,
    bool enabled = true,
    bool hover = false,
    bool bordered = true,
    SnipControlTone tone = SnipControlTone.neutral,
    double? radius,
  }) {
    final r = radius ?? this.radius;
    final shape = BorderRadius.circular(r);
    final isDanger = tone == SnipControlTone.danger;

    Color fill;
    Color? outline;
    var outlineWidth = hairline;

    if (!enabled) {
      // Disabled never gets the full-strength knockout plate — an
      // exclusive-active control downgrades to the selectedFill highlight
      // shape instead, and hover never applies.
      if (active) {
        fill = selectedFill;
        outline = bordered ? selectedFill : null;
      } else {
        fill = Colors.transparent;
        outline = bordered ? border : null;
      }
    } else if (active) {
      if (exclusive) {
        fill = isDanger ? danger : activeFill;
        outline = isDanger ? danger : activeFill;
        outlineWidth = activeBorderWidth;
      } else {
        fill = selectedFill;
        outline = bordered ? (isDanger ? danger : selectedFill) : null;
      }
    } else if (hover) {
      fill = bordered ? Colors.transparent : hoverFill;
      outline = bordered ? (isDanger ? danger : borderStrong) : null;
    } else {
      fill = Colors.transparent;
      outline = bordered ? (isDanger ? danger : border) : null;
    }

    return BoxDecoration(
      color: fill,
      borderRadius: shape,
      border: outline == null
          ? null
          : Border.all(color: outline, width: outlineWidth),
    );
  }

  /// The foreground (icon/label) colour paired with [controlDecoration] for
  /// the exact same arguments — pass the two together so a control's
  /// content can never drift out of sync with its own fill.
  ///
  /// Branches in the same order as [controlDecoration], so the two always
  /// agree on which fill a given argument set produced:
  ///
  /// * `enabled: false` always answers [inkFaint], regardless of every other
  ///   argument — disabled state is signalled by foreground alone,
  ///   [controlDecoration] having already downgraded the fill itself.
  /// * Otherwise, exclusivity is checked *before* tone, because
  ///   [controlDecoration] only ever paints the full [activeFill]/[danger]
  ///   knockout plate for the exclusive-active case — a non-exclusive
  ///   selected control stays on [selectedFill] even with a destructive
  ///   [tone]. Knocking its text out to [onDanger] there would put
  ///   [onDanger] directly on [selectedFill], which is not a designed pair
  ///   and is illegible (checked by
  ///   `test/snip_theme_test.dart`'s full-combination contrast sweep). So:
  ///   - **exclusive-active**: [onDanger] for `tone: danger`, [onActive]
  ///     otherwise — the knockout, matching [controlDecoration]'s full-fill
  ///     plate.
  ///   - **non-exclusive selected**: [danger] for `tone: danger` (still
  ///     legible on [selectedFill] — this is the ring colour too), [ink]
  ///     otherwise — a highlight, never a knockout.
  ///   - **resting**: [danger] for `tone: danger` — a destructive control
  ///     reads as destructive even before it's pressed — otherwise [dim]
  ///     selects the secondary tone ([inkMuted]: pass `true` for a
  ///     caption/label under an icon, `false`, the default, for the icon
  ///     itself, which stays full [ink] at rest).
  Color controlForeground({
    required bool active,
    bool exclusive = true,
    bool dim = false,
    bool enabled = true,
    SnipControlTone tone = SnipControlTone.neutral,
  }) {
    if (!enabled) return inkFaint;
    final isDanger = tone == SnipControlTone.danger;
    if (active) {
      if (exclusive) return isDanger ? onDanger : onActive;
      return isDanger ? danger : ink;
    }
    if (isDanger) return danger;
    return dim ? inkMuted : ink;
  }

  /// WCAG relative luminance. Shared by [ringOn] and [ringOnGradient] so
  /// both score contrast the same way `test/snip_theme_test.dart` does.
  static double _luminance(Color c) {
    double channel(double v) => v <= 0.03928
        ? v / 12.92
        : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * channel(c.r) +
        0.7152 * channel(c.g) +
        0.0722 * channel(c.b);
  }

  /// WCAG contrast ratio between two **opaque** colours. Callers ([ringOn],
  /// [ringOnGradient]) are responsible for resolving any translucency to an
  /// opaque, composited colour before calling this — see both methods' own
  /// doc comments for why that step can't be skipped.
  static double _contrast(Color a, Color b) {
    final la = _luminance(a);
    final lb = _luminance(b);
    final hi = math.max(la, lb);
    final lo = math.min(la, lb);
    return (hi + 0.05) / (lo + 0.05);
  }

  /// Resolves [c] to the opaque colour that actually reaches the screen.
  /// Opaque colours pass through untouched. A translucent [c] is composited
  /// over [backdrop] with [Color.alphaBlend] — [backdrop] itself must be
  /// opaque, since compositing over an unresolved backdrop would just move
  /// the same unresolved-alpha problem one level down. Checked
  /// unconditionally (an [ArgumentError], not an `assert`), so this fails
  /// loudly in release builds too, not only in debug.
  static Color _resolveOpaque(Color c, Color? backdrop, String callerName) {
    // Deliberately NOT an assert(): a translucent backdrop composited via
    // Color.alphaBlend below can itself come out translucent, which would
    // then silently reach _luminance/_contrast (ignoring alpha) — exactly
    // the bug this whole step existed to close — with no crash to reveal
    // it, since assert() is stripped in release builds. The translucent-`c`
    // path below has a release-mode backstop for free (`backdrop!` throws
    // a TypeError even with asserts off); this branch had none until this
    // check was moved off assert() and made unconditional, so both halves
    // of this contract now fail loudly in every build mode, not just debug.
    if (backdrop != null && backdrop.a < 1.0) {
      throw ArgumentError(
        '$callerName: backdrop must itself be opaque (a=${backdrop.a}) — '
        'otherwise compositing against it still leaves an unresolved pixel.',
      );
    }
    assert(
      c.a >= 1.0 || backdrop != null,
      "$callerName: this colour is translucent (a=${c.a}), so its raw RGB "
      "is not the colour a viewer actually sees — it blends with whatever "
      "sits behind it. Pass the opaque `backdrop:` it is actually painted "
      "over so contrast is scored against the true composited pixel. "
      "Scoring the raw, unpremultiplied RGB was exactly this method's bug "
      "before the task-6 fix (see the task-6 report) — silently reusing "
      "that bug here would reintroduce it. (In a release build, where this "
      "assert is stripped, the `backdrop!` null-check below throws a "
      "TypeError instead, so this still fails loudly rather than silently.)",
    );
    return c.a >= 1.0 ? c : Color.alphaBlend(c, backdrop!);
  }

  /// A selection-ring colour guaranteed to stay visible against real,
  /// arbitrary colour data — an annotation-palette swatch, a user-chosen
  /// text/fill background, anything this design deliberately lets stay
  /// saturated rather than tokenising. For a multi-stop gradient preview
  /// (the save-as dialog's framing swatches), use [ringOnGradient] instead
  /// — a ring picked against one gradient stop is not guaranteed safe
  /// against the others.
  ///
  /// Monochrome chrome drawn *on* real colour is the one place a fixed token
  /// isn't safe: [ink] alone reads fine against most swatches, but a ring
  /// fixed to [ink] drops to roughly 1.1:1 — effectively invisible — against
  /// a swatch that happens to be close to [ink] itself (a pure-black swatch
  /// in light mode, where [ink] *is* near-black; a pure-white swatch in dark
  /// mode, where [ink] is near-white). [ink] and [onActive] are this
  /// design's two "mark" tones — the near-black/near-white pair the whole
  /// inversion is built from (see the class doc comment) — so this picks
  /// whichever of the two actually contrasts better against [swatchColor]
  /// and uses that instead of assuming [ink] is always the right one.
  ///
  /// [swatchColor] may be translucent (a text/fill background preset with
  /// `alpha < 1` is a real, live case in this app) — pass the opaque
  /// [backdrop] it is actually painted over so this composites the true
  /// rendered pixel before scoring. Omitting [backdrop] for a translucent
  /// [swatchColor] asserts rather than silently scoring the wrong (raw,
  /// unpremultiplied) colour — that silent wrongness is precisely the bug
  /// this parameter exists to close, not a hypothetical one: it was live in
  /// `style_picker.dart`'s preset swatches and `editor_canvas.dart`'s colour
  /// readout before the task-6 fix. [backdrop] is unused, and may be
  /// omitted, when [swatchColor] is already opaque.
  ///
  /// Any future call site that draws chrome on top of real colour data
  /// should reach for this rather than hardcoding [ink] — that hardcoding is
  /// exactly the bug this method exists to close (see
  /// `test/snip_theme_test.dart`'s full-palette contrast sweep and the
  /// task-4 report).
  Color ringOn(Color swatchColor, {Color? backdrop}) {
    final resolved = _resolveOpaque(swatchColor, backdrop, 'SnipTheme.ringOn');
    return _contrast(ink, resolved) >= _contrast(onActive, resolved)
        ? ink
        : onActive;
  }

  /// [ringOn]'s multi-stop counterpart, for chrome drawn over a gradient
  /// rather than a single flat colour — the save-as dialog's
  /// framing-gradient previews (`AppColors.framingGradients`) are the live
  /// case. A ring picked against just one endpoint can clear 3:1 there and
  /// still fail against the other: [ringOn] takes one colour and can't see
  /// this by construction, which is exactly the gap this method closes.
  ///
  /// Picks whichever of [ink]/[onActive] clears the better **worst-case**
  /// contrast across every entry in [stops] — so the returned ring is
  /// guaranteed safe against every stop, not merely the one it happened to
  /// be checked against.
  ///
  /// Every entry in [stops] must be opaque (asserted) — the same
  /// requirement [ringOn] places on [swatchColor], for the same reason: a
  /// translucent stop's raw RGB is not the colour a viewer actually sees.
  /// `AppColors.framingGradients` ships fully opaque stops, so this is not
  /// a live constraint today, but a future gradient with a translucent stop
  /// should composite it before calling this rather than have that
  /// silently under-score here.
  Color ringOnGradient(List<Color> stops) {
    assert(
      stops.isNotEmpty,
      'SnipTheme.ringOnGradient: stops must not be empty.',
    );
    for (final s in stops) {
      _resolveOpaque(s, null, 'SnipTheme.ringOnGradient');
    }

    double worstContrast(Color ring) =>
        stops.map((s) => _contrast(ring, s)).reduce(math.min);

    return worstContrast(ink) >= worstContrast(onActive) ? ink : onActive;
  }

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

  const SnipThemeScope({super.key, required this.theme, required super.child});

  @override
  bool updateShouldNotify(SnipThemeScope oldWidget) => oldWidget.theme != theme;
}
