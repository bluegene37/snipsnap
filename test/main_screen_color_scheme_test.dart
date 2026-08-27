import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/main_screen.dart';

/// Guards `snipColorScheme` (`lib/views/main_screen.dart`), the hand-built
/// replacement for `ColorScheme.fromSeed`. `fromSeed`'s `SchemeTonalSpot`
/// algorithm hardcodes non-zero chroma for `secondary`/`tertiary` and every
/// `*Container`/`outline`/`surfaceContainer*` role regardless of the seed
/// colour's own chroma, so a neutral seed still produced a chromatic scheme.
/// `snipColorScheme` fills every role explicitly from `SnipTheme` tokens
/// instead; this file is the assertion that keeps that fix from regressing.
///
/// `MainScreen` itself cannot be pumped (it builds an `EditorCanvas`, which
/// emits `Image.file`, which hangs `flutter_tester`), which is exactly why
/// `snipColorScheme` is a plain top-level function: these are ordinary unit
/// tests, no widget tree required.
void main() {
  bool isNeutral(Color c) {
    final maxC = math.max(c.r, math.max(c.g, c.b));
    final minC = math.min(c.r, math.min(c.g, c.b));
    return (maxC - minC) < 0.04;
  }

  test('every ColorScheme role is neutral except the error roles', () {
    for (final mode in SnipThemeMode.values) {
      final t = SnipTheme.forMode(mode);
      final scheme = snipColorScheme(t);

      // Only error/errorContainer (== SnipTheme.danger) are allowed —
      // required, even — to carry chroma. onError/onErrorContainer
      // (== SnipTheme.onDanger) are deliberately neutral: they are the
      // knocked-out label drawn *on* the red fill, not the fill itself, the
      // same relationship onActive has to activeFill everywhere else in
      // this design language. Only they belong in the "must stay neutral"
      // set below alongside every genuinely neutral role.
      final mustCarryChroma = <String, Color>{
        'error': scheme.error,
        'errorContainer': scheme.errorContainer,
      };
      final everyOtherRole = <String, Color>{
        'onError': scheme.onError,
        'onErrorContainer': scheme.onErrorContainer,
        'primary': scheme.primary,
        'onPrimary': scheme.onPrimary,
        'primaryContainer': scheme.primaryContainer,
        'onPrimaryContainer': scheme.onPrimaryContainer,
        'primaryFixed': scheme.primaryFixed,
        'primaryFixedDim': scheme.primaryFixedDim,
        'onPrimaryFixed': scheme.onPrimaryFixed,
        'onPrimaryFixedVariant': scheme.onPrimaryFixedVariant,
        'secondary': scheme.secondary,
        'onSecondary': scheme.onSecondary,
        'secondaryContainer': scheme.secondaryContainer,
        'onSecondaryContainer': scheme.onSecondaryContainer,
        'secondaryFixed': scheme.secondaryFixed,
        'secondaryFixedDim': scheme.secondaryFixedDim,
        'onSecondaryFixed': scheme.onSecondaryFixed,
        'onSecondaryFixedVariant': scheme.onSecondaryFixedVariant,
        'tertiary': scheme.tertiary,
        'onTertiary': scheme.onTertiary,
        'tertiaryContainer': scheme.tertiaryContainer,
        'onTertiaryContainer': scheme.onTertiaryContainer,
        'tertiaryFixed': scheme.tertiaryFixed,
        'tertiaryFixedDim': scheme.tertiaryFixedDim,
        'onTertiaryFixed': scheme.onTertiaryFixed,
        'onTertiaryFixedVariant': scheme.onTertiaryFixedVariant,
        'surface': scheme.surface,
        'onSurface': scheme.onSurface,
        'surfaceDim': scheme.surfaceDim,
        'surfaceBright': scheme.surfaceBright,
        'surfaceContainerLowest': scheme.surfaceContainerLowest,
        'surfaceContainerLow': scheme.surfaceContainerLow,
        'surfaceContainer': scheme.surfaceContainer,
        'surfaceContainerHigh': scheme.surfaceContainerHigh,
        'surfaceContainerHighest': scheme.surfaceContainerHighest,
        'onSurfaceVariant': scheme.onSurfaceVariant,
        'outline': scheme.outline,
        'outlineVariant': scheme.outlineVariant,
        'shadow': scheme.shadow,
        'scrim': scheme.scrim,
        'inverseSurface': scheme.inverseSurface,
        'onInverseSurface': scheme.onInverseSurface,
        'inversePrimary': scheme.inversePrimary,
        'surfaceTint': scheme.surfaceTint,
      };

      everyOtherRole.forEach((name, color) {
        expect(
          isNeutral(color),
          isTrue,
          reason:
              '$mode: $name (${color.toARGB32().toRadixString(16)}) '
              'should be neutral but carries chroma',
        );
      });

      // The other half of the assertion: error/errorContainer must actually
      // still carry danger's chroma, so this test cannot pass by accident
      // if a future edit neutralises everything including error.
      mustCarryChroma.forEach((name, color) {
        expect(
          isNeutral(color),
          isFalse,
          reason:
              '$mode: $name has lost its chroma — should read from '
              'SnipTheme.danger',
        );
      });
    }
  });

  test('snipColorScheme never calls ColorScheme.fromSeed', () {
    // Source-level guard: even if the neutrality assertion above were
    // weakened, this keeps a future edit from quietly reintroducing
    // fromSeed's hardcoded-chroma algorithm. Checks for the call form (with
    // the opening paren) rather than the bare name, since the doc comment
    // above `snipColorScheme` legitimately names `ColorScheme.fromSeed` in
    // prose to explain why it is not used.
    final source = File('lib/views/main_screen.dart').readAsStringSync();
    expect(source, isNot(contains('ColorScheme.fromSeed(')));
  });
}
