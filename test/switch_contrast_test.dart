import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/main_screen.dart';

/// WCAG contrast, duplicated locally rather than shared — same small helper
/// `test/snip_theme_test.dart` and `test/style_picker_test.dart` each define
/// for themselves.
double _contrast(Color a, Color b) {
  double luminance(Color c) {
    double channel(double v) =>
        v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
  }

  final la = luminance(a);
  final lb = luminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// The four `Switch`es in this app (`style_picker.dart` x3,
/// `save_as_dialog.dart` x1) set only `activeTrackColor`. Everything about
/// the **off** state therefore falls through to `_SwitchDefaultsM3`, which
/// reads `colorScheme.outline` for the thumb and track outline and
/// `surfaceContainerHighest` for the track — roles [snipColorScheme] maps to
/// [SnipTheme.border] and [SnipTheme.surfaceRaised], both near-invisible
/// hairline tones. The result measured 1.38:1 / 1.43:1 / 1.04:1 in light.
///
/// That was a regression this branch introduced, not a pre-existing wart:
/// before the hand-built 46-role scheme, `outline` was unspecified and fell
/// back to `onBackground` (`Colors.black`), giving the off thumb 4.58:1.
/// [snipSwitchTheme] is the repair; this file is its guard.
///
/// Every switch in the app sits on a `t.surface` panel — the style picker's
/// body and the save-as dialog's `AlertDialog` background are both exactly
/// that — so `t.surface` is the panel these are scored against. `surfaceRaised`
/// is checked too, so a switch moved onto a raised card stays covered.
void main() {
  const minRatio = 3.0;

  /// Resolves a switch colour out of the production [ThemeData], not out of
  /// [snipSwitchTheme] directly — so a future edit that builds the theme but
  /// forgets to attach it to `ThemeData.switchTheme` fails here.
  Color resolve(
    WidgetStateProperty<Color?>? property,
    Set<WidgetState> states,
    String what,
  ) {
    expect(property, isNotNull, reason: 'switchTheme.$what is unset');
    final c = property!.resolve(states);
    expect(c, isNotNull, reason: 'switchTheme.$what resolved null for $states');
    return c!;
  }

  for (final mode in SnipThemeMode.values) {
    final label = mode.name;
    final t = SnipTheme.forMode(mode);
    final sw = snipThemeData(t).switchTheme;

    test('[$label] the OFF thumb clears $minRatio:1 against its own track', () {
      final thumb = resolve(sw.thumbColor, const {}, 'thumbColor');
      final track = resolve(sw.trackColor, const {}, 'trackColor');

      final ratio = _contrast(thumb, track);
      expect(ratio, greaterThanOrEqualTo(minRatio),
          reason: '$label: off thumb $thumb on off track $track only clears '
              '${ratio.toStringAsFixed(2)}:1 — the M3 default measured 1.43:1 light / '
              '1.34:1 dark, which is the bug this pins');
    });

    test('[$label] the ON thumb clears $minRatio:1 against its own track', () {
      const on = {WidgetState.selected};
      final thumb = resolve(sw.thumbColor, on, 'thumbColor');
      final track = resolve(sw.trackColor, on, 'trackColor');

      final ratio = _contrast(thumb, track);
      expect(ratio, greaterThanOrEqualTo(minRatio),
          reason: '$label: on thumb $thumb on on track $track only clears '
              '${ratio.toStringAsFixed(2)}:1');
    });

    test('[$label] the OFF switch is findable at all — outline against the panel', () {
      // The off track deliberately carries no fill of its own (t.surface on a
      // t.surface panel), per the skeleton convention that a resting control
      // is a hairline, not a plate. That makes the outline the *only* thing
      // delineating the control, so it has to clear on its own — this is the
      // measurement the old t.border outline failed at 1.38:1.
      final outline = resolve(sw.trackOutlineColor, const {}, 'trackOutlineColor');

      for (final panel in <String, Color>{'surface': t.surface, 'surfaceRaised': t.surfaceRaised}
          .entries) {
        final ratio = _contrast(outline, panel.value);
        expect(ratio, greaterThanOrEqualTo(minRatio),
            reason: '$label: off track outline $outline on ${panel.key} '
                '${panel.value} only clears ${ratio.toStringAsFixed(2)}:1');
      }
    });

    test('[$label] the ON track reads as a plate against the panel', () {
      final track = resolve(sw.trackColor, const {WidgetState.selected}, 'trackColor');
      final ratio = _contrast(track, t.surface);
      expect(ratio, greaterThanOrEqualTo(minRatio),
          reason: '$label: on track $track on panel ${t.surface} only clears '
              '${ratio.toStringAsFixed(2)}:1');
    });

    test('[$label] on and off are distinguishable from each other, not just visible', () {
      // Two states that each clear 3:1 against their own backdrop could still
      // look identical to each other. The design distinguishes them by
      // inversion, so the thumbs must land on opposite sides.
      final offThumb = resolve(sw.thumbColor, const {}, 'thumbColor');
      final onThumb = resolve(sw.thumbColor, const {WidgetState.selected}, 'thumbColor');
      final ratio = _contrast(offThumb, onThumb);
      expect(ratio, greaterThanOrEqualTo(minRatio),
          reason: '$label: off thumb $offThumb and on thumb $onThumb are only '
              '${ratio.toStringAsFixed(2)}:1 apart — the states would read alike');
    });

    test('[$label] the M3 defaults this replaces really were below $minRatio:1', () {
      // The other half of the assertion: without this, the thresholds above
      // could be met by a theme that had simply never been broken, and the
      // "pre-existing, not a regression" misdiagnosis could recur.
      final scheme = snipColorScheme(t);
      // _SwitchDefaultsM3: unselected thumb and track outline = outline,
      // unselected track = surfaceContainerHighest.
      expect(_contrast(scheme.outline, scheme.surfaceContainerHighest), lessThan(minRatio),
          reason: '$label: M3 default off thumb-vs-track');
      expect(_contrast(scheme.outline, t.surface), lessThan(minRatio),
          reason: '$label: M3 default off outline-vs-panel');
    });

    test('[$label] a disabled switch never claims to be interactive', () {
      const disabledOn = {WidgetState.selected, WidgetState.disabled};
      final thumb = resolve(sw.thumbColor, const {WidgetState.disabled}, 'thumbColor');
      final onTrack = resolve(sw.trackColor, disabledOn, 'trackColor');

      expect(thumb, t.inkFaint,
          reason: '$label: disabled foregrounds are inkFaint everywhere else in this design');
      expect(onTrack, t.selectedFill,
          reason: '$label: a disabled-and-on switch must downgrade off the full activeFill '
              'plate, same as SnipTheme.controlDecoration does');
    });
  }

  // Everything above resolves out of `snipThemeData(t).switchTheme`, which
  // already proves the theme is attached. This last one closes the remaining
  // gap: that a real Switch mounted under that ThemeData actually reads it,
  // rather than the call sites' own `activeTrackColor` or an M3 default
  // winning. Equality on SwitchThemeData itself cannot do this — its
  // WidgetStateProperty fields are closures and never compare equal.
  for (final mode in SnipThemeMode.values) {
    final t = SnipTheme.forMode(mode);

    testWidgets('[${mode.name}] a mounted Switch resolves these colours', (tester) async {
      late SwitchThemeData seen;
      await tester.pumpWidget(
        SnipThemeScope(
          theme: t,
          child: MaterialApp(
            theme: snipThemeData(t),
            home: Scaffold(
              body: Builder(builder: (context) {
                seen = Theme.of(context).switchTheme;
                // Mirrors the four real call sites, which set only this.
                return Switch(
                  value: false,
                  activeTrackColor: t.activeFill,
                  onChanged: (_) {},
                );
              }),
            ),
          ),
        ),
      );

      expect(find.byType(Switch), findsOneWidget);
      expect(seen.thumbColor?.resolve(const {}), t.ink,
          reason: '${mode.name}: a mounted Switch must see the ink off-thumb');
      expect(seen.trackOutlineColor?.resolve(const {}), t.inkMuted,
          reason: '${mode.name}: a mounted Switch must see the inkMuted off-outline');
    });
  }
}
