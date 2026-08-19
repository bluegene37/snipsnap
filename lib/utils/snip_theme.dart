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
/// Three chrome needs beyond the active/inactive binary have sanctioned
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
/// * **Destructive** — [danger] and [onDanger] are the one sanctioned
///   chromatic exception to the monochrome rule. Deleting a capture is
///   irreversible, and the safety affordance of a red warning outweighs
///   monochrome purity; naming it a token keeps the exception greppable
///   and singular instead of every call site picking its own red.
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
    required this.selectedFill,
    required this.hoverFill,
    required this.danger,
    required this.onDanger,
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
        selectedFill: Color(0xFF2A2A2A),
        hoverFill: Color(0xFF202020),
        danger: Color(0xFFFF6B6B),
        onDanger: Color(0xFF141414),
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
