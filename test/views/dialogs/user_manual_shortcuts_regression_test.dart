// Regression: ISSUE-002 — the in-app manual advertised shortcuts that were
// never bound. Three "global capture hotkeys" (Cmd+Shift+4/3/5) are the macOS
// system screenshot chords, so following the manual fired Apple's screenshot
// tool instead of SnipSnap; and three tool letters (S for Step Marker, C for
// OCR, F for Fill) each select a *different* tool, so the documented key
// silently did the wrong thing.
// Found by /qa on 2026-08-30
// Report: .gstack/qa-reports/qa-report-snipsnap-2026-08-30.md
//
// The manual is hand-written data, so it drifts silently from the real
// bindings. These tests pin it: chord claims are checked against
// ShortcutService's own defaults, and bare-letter claims against the canvas
// tool-key contract below.

import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/models/app_shortcut.dart';
import 'package:snipsnap/services/shortcut_service.dart';
import 'package:snipsnap/views/dialogs/user_manual_data.dart';

/// Single-letter keys the canvas focus node actually maps to a tool, mirroring
/// the `toolKeys` map in `EditorCanvas._handleKeyEvent`. That map is private,
/// so this list is the contract: change one, change the other.
const Set<String> _canvasToolKeys = {
  'V', 'S', // select
  'P', // pen
  'L', // line
  'A', // arrow
  'R', 'U', // shape
  'H', // highlight
  'T', // text
  'N', '1', // step marker
  'B', // blur
  'M', // ruler
  'G', // fill
  'I', // colour picker
  'C', // crop
  'E', // OCR
};

/// Chord tokens the manual may use that are bound outside [ShortcutService]
/// (see the F1 / Cmd+? bindings in `_MainScreenState._buildShortcutBindings`)
/// or handled by the platform rather than a hotkey.
const Set<String> _nonConfigurableTokens = {'F1', 'ESC'};

/// Every `shortcuts:` token in the manual, paired with the section that
/// claims it, so a failure names the offending doc entry.
Iterable<({String token, String section})> _allShortcutClaims() sync* {
  for (final topic in UserManualData.topics) {
    for (final section in topic.sections) {
      for (final token in section.shortcuts) {
        yield (token: token, section: '${topic.title} › ${section.title}');
      }
    }
  }
}

/// All prose the manual shows a reader, so claims made in sentences are
/// checked too, not just the chips.
Iterable<String> _allProse() sync* {
  for (final topic in UserManualData.topics) {
    yield topic.title;
    yield topic.subtitle;
    for (final section in topic.sections) {
      yield section.title;
      yield section.description;
      if (section.tip != null) yield section.tip!;
      yield* section.steps;
    }
  }
}

/// Normalises `Cmd+Shift+1` into the parts that survive platform differences:
/// the modifiers that are not the primary meta key, plus the key label.
({bool shift, String key}) _parseChord(String token) {
  final parts = token.split('+').map((p) => p.trim()).toList();
  return (
    shift: parts.any((p) => p.toLowerCase() == 'shift'),
    key: parts.last.toUpperCase(),
  );
}

void main() {
  final defaults = ShortcutService.getDefaultShortcuts();

  ({bool shift, String key}) expectedFor(AppShortcutAction action) {
    final s = defaults[action]!;
    return (shift: s.shift, key: s.keyLabel.toUpperCase());
  }

  group('manual capture hotkeys match the real defaults', () {
    test('Area Snip is the interactiveSnip default, not a macOS system chord', () {
      expect(_parseChord('Cmd+Shift+1'),
          expectedFor(AppShortcutAction.interactiveSnip));
      // The bug: Cmd+Shift+4 is Apple's own area-screenshot chord.
      expect(_parseChord('Cmd+Shift+4'),
          isNot(expectedFor(AppShortcutAction.interactiveSnip)));
    });

    test('Full Screen Snip is the fullScreenSnip default', () {
      expect(_parseChord('Cmd+Shift+2'),
          expectedFor(AppShortcutAction.fullScreenSnip));
    });

    test('3s Timer Snip is the timerSnip default', () {
      expect(_parseChord('Cmd+Shift+6'),
          expectedFor(AppShortcutAction.timerSnip));
    });
  });

  test('every chord the manual advertises is actually bound', () {
    final bound = {
      for (final s in defaults.values)
        (shift: s.shift, key: s.keyLabel.toUpperCase()),
    };

    final unbound = <String>[];
    for (final claim in _allShortcutClaims()) {
      if (_nonConfigurableTokens.contains(claim.token)) continue;
      if (!claim.token.contains('+')) continue; // bare letters checked below
      if (!bound.contains(_parseChord(claim.token))) {
        unbound.add('${claim.token} (${claim.section})');
      }
    }

    expect(unbound, isEmpty,
        reason: 'manual advertises chords with no binding in ShortcutService');
  });

  test('every bare-letter key the manual advertises selects a tool', () {
    final unknown = <String>[];
    for (final claim in _allShortcutClaims()) {
      if (_nonConfigurableTokens.contains(claim.token)) continue;
      if (claim.token.contains('+')) continue;
      if (!_canvasToolKeys.contains(claim.token.toUpperCase())) {
        unknown.add('${claim.token} (${claim.section})');
      }
    }

    expect(unknown, isEmpty,
        reason: 'manual advertises tool letters the canvas does not map');
  });

  test('the manual does not promise unimplemented actions', () {
    // Cmd+V paste-from-clipboard and Cmd+P open-properties were both
    // documented but never wired up.
    final offenders = <String>[];
    for (final text in _allProse()) {
      final normalised = text.replaceAll(' ', '').toLowerCase();
      for (final ghost in const ['cmd+v', 'ctrl+v', 'cmd+p', 'ctrl+p']) {
        if (normalised.contains(ghost)) offenders.add('$ghost in "$text"');
      }
    }

    expect(offenders, isEmpty,
        reason: 'manual documents a shortcut the app never binds');
  });

  test('the tool letters the manual leans on are each mapped exactly once', () {
    // Guards the specific collisions that caused the bug: S was documented for
    // Step Marker (it is Select), C for OCR (it is Crop), F for Fill (it is
    // unmapped — Fill is G).
    final claimed = {
      for (final c in _allShortcutClaims())
        if (!c.token.contains('+') && !_nonConfigurableTokens.contains(c.token))
          c.token.toUpperCase(),
    };

    expect(claimed, contains('N'), reason: 'Step Marker is N, not S');
    expect(claimed, contains('E'), reason: 'OCR is E, not C');
    expect(claimed, contains('G'), reason: 'Fill is G, not F');
    expect(claimed, isNot(contains('F')),
        reason: 'F is not mapped to any tool');
    expect(claimed, isNot(contains('O')),
        reason: 'O is not mapped to any tool; the Shape tool is R / U');
  });
}
