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

  /// The outline/fill for a control in one of this design's three states:
  /// resting (hairline, no fill), a highlighted-but-not-exclusive selection
  /// (`exclusive: false` — [selectedFill], e.g. an independently
  /// toggleable panel that can be open at the same time as some other
  /// control), or the app's one exclusive active control (`exclusive:
  /// true`, the default — [activeFill], meant to be knocked out via
  /// [controlForeground]). [radius] defaults to the [radius] field; pass an
  /// explicit value to match a control's own corner radius.
  ///
  /// This exists so the same three-state shape doesn't get hand-duplicated
  /// — and occasionally gotten subtly wrong (the resting border in
  /// particular) — at every call site. [controlForeground] is its
  /// foreground-colour companion; use them together so a control's icon
  /// and label can never drift out of sync with its own fill.
  BoxDecoration controlDecoration({
    required bool active,
    bool exclusive = true,
    double? radius,
  }) {
    final r = radius ?? this.radius;
    if (!active) {
      return BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(r),
        border: Border.all(color: border, width: hairline),
      );
    }
    if (exclusive) {
      return BoxDecoration(
        color: activeFill,
        borderRadius: BorderRadius.circular(r),
        border: Border.all(color: activeFill, width: activeBorderWidth),
      );
    }
    return BoxDecoration(
      color: selectedFill,
      borderRadius: BorderRadius.circular(r),
      border: Border.all(color: selectedFill, width: hairline),
    );
  }

  /// The foreground (icon/label) colour paired with [controlDecoration] for
  /// the same `(active, exclusive)` state. A selected-but-not-exclusive
  /// control is a highlight, not an inversion, so its foreground is
  /// ordinary [ink] — only the exclusive-active case knocks out to
  /// [onActive]. [dim] selects the resting state's secondary tone
  /// ([inkMuted]): pass `true` for a caption/label under an icon, `false`
  /// (the default) for the icon itself, which stays full [ink] at rest.
  Color controlForeground({
    required bool active,
    bool exclusive = true,
    bool dim = false,
  }) {
    if (active) return exclusive ? onActive : ink;
    return dim ? inkMuted : ink;
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

  const SnipThemeScope({
    super.key,
    required this.theme,
    required super.child,
  });

  @override
  bool updateShouldNotify(SnipThemeScope oldWidget) => oldWidget.theme != theme;
}
