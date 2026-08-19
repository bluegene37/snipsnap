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
         t.border, t.borderStrong, t.activeFill, t.onActive,
         t.selectedFill, t.hoverFill, t.danger, t.onDanger],
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

  test('ink stays legible on selectedFill and hoverFill', () {
    // selectedFill (non-exclusive selection) and hoverFill (hover-as-a-wash)
    // both still carry the ordinary ink token as foreground, not a knocked-
    // out label — so ink must clear body-text contrast against each.
    for (final mode in SnipThemeMode.values) {
      final t = SnipTheme.forMode(mode);
      expect(_contrast(t.ink, t.selectedFill), greaterThanOrEqualTo(4.5),
          reason: '$mode: ink on selectedFill');
      expect(_contrast(t.ink, t.hoverFill), greaterThanOrEqualTo(4.5),
          reason: '$mode: ink on hoverFill');
    }
  });

  test('danger meets WCAG AA against onDanger and stays visible on surface',
      () {
    for (final mode in SnipThemeMode.values) {
      final t = SnipTheme.forMode(mode);
      expect(_contrast(t.onDanger, t.danger), greaterThanOrEqualTo(4.5),
          reason: '$mode: onDanger on danger');
      expect(_contrast(t.danger, t.surface), greaterThanOrEqualTo(3.0),
          reason: '$mode: danger on surface');
    }
  });

  test('dark is an inversion, not a tint', () {
    final l = SnipTheme.light();
    final d = SnipTheme.dark();
    expect(_luminance(l.ink), lessThan(_luminance(l.surface)));
    expect(_luminance(d.ink), greaterThan(_luminance(d.surface)));
  });

  test('the theme is monochrome — no chroma in any chrome token', () {
    // danger/onDanger are deliberately excluded: they are the one sanctioned
    // chromatic exception to the monochrome rule (see SnipTheme's doc
    // comment), not an oversight.
    for (final mode in SnipThemeMode.values) {
      final t = SnipTheme.forMode(mode);
      for (final c in [t.canvas, t.surface, t.surfaceRaised, t.ink,
                       t.inkMuted, t.inkFaint, t.activeFill, t.onActive,
                       t.selectedFill, t.hoverFill]) {
        final maxC = math.max(c.r, math.max(c.g, c.b));
        final minC = math.min(c.r, math.min(c.g, c.b));
        expect(maxC - minC, lessThan(0.04),
            reason: '$mode: ${c.toARGB32().toRadixString(16)} is not neutral');
      }
    }
  });

  test('danger is the only chromatic chrome token', () {
    // The monochrome test above intentionally skips danger/onDanger. Assert
    // here that danger actually does carry chroma in both modes, so a future
    // edit that accidentally neutralises it (defeating the point of the
    // token) is caught rather than silently passing every other test.
    for (final mode in SnipThemeMode.values) {
      final t = SnipTheme.forMode(mode);
      final maxC = math.max(t.danger.r, math.max(t.danger.g, t.danger.b));
      final minC = math.min(t.danger.r, math.min(t.danger.g, t.danger.b));
      expect(maxC - minC, greaterThanOrEqualTo(0.04),
          reason: '$mode: danger has lost its chroma');
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
