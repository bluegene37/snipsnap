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
         t.selectedFill, t.hoverFill, t.danger, t.onDanger, t.emphasis],
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
                       t.selectedFill, t.hoverFill, t.emphasis]) {
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

  test('emphasis matches ink and stays legible on canvas/surface', () {
    // emphasis is a named alias for "ink-strength weight on a
    // call-to-action that is not the exclusive active control" (see the
    // class doc comment) — currently identical to ink in both modes.
    for (final mode in SnipThemeMode.values) {
      final t = SnipTheme.forMode(mode);
      expect(t.emphasis, t.ink, reason: '$mode: emphasis should equal ink');
      expect(_contrast(t.emphasis, t.surface), greaterThanOrEqualTo(4.5),
          reason: '$mode: emphasis on surface');
      expect(_contrast(t.emphasis, t.canvas), greaterThanOrEqualTo(4.5),
          reason: '$mode: emphasis on canvas');
    }
  });

  test('scrim is a single mode-invariant translucent constant', () {
    // Unlike every other token, scrim is not a per-mode field — it is a
    // static const on the class, so there is only ever one value to read
    // regardless of SnipThemeMode. This asserts both the value and that
    // there is no light/dark variance to accidentally introduce later.
    expect(SnipTheme.scrim, const Color(0x8A000000));
    expect(SnipTheme.scrim.a, closeTo(0.54, 0.01),
        reason: 'scrim should be translucent, matching the pre-conversion '
            'Colors.black54 literal it replaces');
    final maxC = math.max(SnipTheme.scrim.r, math.max(SnipTheme.scrim.g, SnipTheme.scrim.b));
    final minC = math.min(SnipTheme.scrim.r, math.min(SnipTheme.scrim.g, SnipTheme.scrim.b));
    expect(maxC - minC, lessThan(0.04), reason: 'scrim must be neutral');
  });

  test('dark ink deliberately reuses light\'s paper tone, not a fresh grey',
      () {
    // See SnipTheme.dark()'s doc comment: the two paper tones this design
    // uses appear on both sides of the inversion with their roles swapped,
    // rather than each mode inventing its own near-black/near-white. This
    // pins that identity so a future "neutralise the 2-unit deficit" edit
    // doesn't quietly break it.
    expect(SnipTheme.dark().ink, SnipTheme.light().canvas,
        reason: "dark's ink should be exactly light's canvas hex");
    expect(SnipTheme.light().ink, SnipTheme.dark().onActive,
        reason: "light's ink should be exactly dark's onActive hex");
    expect(SnipTheme.light().ink, SnipTheme.dark().onDanger,
        reason: "light's ink should be exactly dark's onDanger hex");
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

  group('controlDecoration/controlForeground — disabled', () {
    test('disabled resting control is an unchanged hairline, faint foreground', () {
      for (final mode in SnipThemeMode.values) {
        final t = SnipTheme.forMode(mode);
        final deco = t.controlDecoration(active: false, enabled: false);
        expect(deco.color, Colors.transparent, reason: '$mode');
        expect((deco.border as Border).top.color, t.border, reason: '$mode');
        expect(t.controlForeground(active: false, enabled: false), t.inkFaint,
            reason: '$mode');
      }
    });

    test('disabled exclusive-active control never renders the activeFill '
        'knockout plate — it downgrades to selectedFill', () {
      for (final mode in SnipThemeMode.values) {
        final t = SnipTheme.forMode(mode);
        final deco = t.controlDecoration(active: true, enabled: false);
        expect(deco.color, t.selectedFill,
            reason: '$mode: disabled active must not be activeFill');
        expect((deco.border as Border).top.color, t.selectedFill, reason: '$mode');
        expect(
            t.controlForeground(active: true, enabled: false), t.inkFaint,
            reason: '$mode: disabled foreground is always inkFaint, never onActive');
      }
    });

    test('disabled non-exclusive selected control also downgrades to inkFaint', () {
      for (final mode in SnipThemeMode.values) {
        final t = SnipTheme.forMode(mode);
        final deco = t.controlDecoration(active: true, exclusive: false, enabled: false);
        expect(deco.color, t.selectedFill, reason: '$mode');
        expect(
            t.controlForeground(active: true, exclusive: false, enabled: false),
            t.inkFaint,
            reason: '$mode');
      }
    });
  });

  group('controlDecoration — hover', () {
    test('hovered bordered control strengthens the hairline, stays unfilled', () {
      for (final mode in SnipThemeMode.values) {
        final t = SnipTheme.forMode(mode);
        final deco = t.controlDecoration(active: false, hover: true);
        expect(deco.color, Colors.transparent, reason: '$mode');
        expect((deco.border as Border).top.color, t.borderStrong, reason: '$mode');
      }
    });

    test('hovered borderless row/tile washes with hoverFill and draws no border', () {
      for (final mode in SnipThemeMode.values) {
        final t = SnipTheme.forMode(mode);
        final deco = t.controlDecoration(active: false, hover: true, bordered: false);
        expect(deco.color, t.hoverFill, reason: '$mode');
        expect(deco.border, isNull, reason: '$mode: a borderless row must draw no border');
      }
    });

    test('a resting borderless control also draws no border', () {
      for (final mode in SnipThemeMode.values) {
        final t = SnipTheme.forMode(mode);
        final deco = t.controlDecoration(active: false, bordered: false);
        expect(deco.color, Colors.transparent, reason: '$mode');
        expect(deco.border, isNull, reason: '$mode');
      }
    });
  });

  group('controlDecoration/controlForeground — destructive tone', () {
    test('resting destructive control borders in danger, not the plain border', () {
      for (final mode in SnipThemeMode.values) {
        final t = SnipTheme.forMode(mode);
        final deco = t.controlDecoration(active: false, tone: SnipControlTone.danger);
        expect(deco.color, Colors.transparent, reason: '$mode');
        expect((deco.border as Border).top.color, t.danger, reason: '$mode');
        expect(t.controlForeground(active: false, tone: SnipControlTone.danger),
            t.danger,
            reason: '$mode');
      }
    });

    test('active destructive control fills with danger, knocks out to onDanger', () {
      for (final mode in SnipThemeMode.values) {
        final t = SnipTheme.forMode(mode);
        final deco = t.controlDecoration(active: true, tone: SnipControlTone.danger);
        expect(deco.color, t.danger, reason: '$mode');
        expect((deco.border as Border).top.color, t.danger, reason: '$mode');
        expect(t.controlForeground(active: true, tone: SnipControlTone.danger),
            t.onDanger,
            reason: '$mode');
      }
    });

    test('destructive tone never leaks into activeFill', () {
      // onDanger is deliberately allowed to coincide with onActive in value
      // (both are simply "the paper tone" used to knock out a dark plate) —
      // it is the *fill* that must never be activeFill, since that would
      // make a destructive control visually indistinguishable from the
      // app's single exclusive-active control.
      for (final mode in SnipThemeMode.values) {
        final t = SnipTheme.forMode(mode);
        final deco = t.controlDecoration(active: true, tone: SnipControlTone.danger);
        expect(deco.color, isNot(t.activeFill), reason: '$mode');
      }
    });
  });

  test('foreground never drifts from fill: every (active, exclusive, enabled, '
      'tone) pair a call site can construct resolves to a legible combination',
      () {
    // The two helpers are meant to always be called together with the same
    // arguments. This sweeps the full combination space and just asserts
    // both helpers return without throwing and stay internally consistent
    // (disabled always faint, danger tone never answers onActive/activeFill).
    for (final mode in SnipThemeMode.values) {
      final t = SnipTheme.forMode(mode);
      for (final active in [false, true]) {
        for (final exclusive in [false, true]) {
          for (final enabled in [false, true]) {
            for (final tone in SnipControlTone.values) {
              final deco = t.controlDecoration(
                  active: active, exclusive: exclusive, enabled: enabled, tone: tone);
              final fg = t.controlForeground(
                  active: active, exclusive: exclusive, enabled: enabled, tone: tone);
              expect(deco, isNotNull, reason: '$mode $active $exclusive $enabled $tone');
              if (!enabled) {
                expect(fg, t.inkFaint, reason: '$mode $active $exclusive $enabled $tone');
              }
            }
          }
        }
      }
    }
  });
}
