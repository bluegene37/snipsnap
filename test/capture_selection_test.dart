// The capture overlay's state machine. It used to be a one-shot gesture —
// mouse-up captured whatever you happened to release on — and is now a
// selection you settle, adjust and confirm. That is a real state machine, and
// this is where it is pinned, without a window or a screen.

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/views/capture/capture_selection.dart';

CaptureSelectionModel _model() =>
    CaptureSelectionModel(bounds: const Rect.fromLTWH(0, 0, 1000, 800));

/// Drags from [from] to [to] and settles, as one gesture.
bool _drag(CaptureSelectionModel m, Offset from, Offset to) {
  m.pointerDown(from);
  m.pointerMove(to);
  return m.pointerUp();
}

void main() {
  group('drawing a selection', () {
    test('a drag settles into adjusting rather than capturing', () {
      final m = _model();
      final wasClick = _drag(m, const Offset(100, 100), const Offset(400, 300));

      expect(
        wasClick,
        isFalse,
        reason: 'a real drag is not the click shortcut',
      );
      expect(m.phase, OverlayPhase.adjusting);
      expect(m.selection, const Rect.fromLTRB(100, 100, 400, 300));
      expect(
        m.showsChrome,
        isTrue,
        reason: 'grips and the button belong up now',
      );
    });

    test('dragging up and to the left still yields a normalised rect', () {
      final m = _model();
      _drag(m, const Offset(400, 300), const Offset(100, 100));
      expect(m.selection, const Rect.fromLTRB(100, 100, 400, 300));
    });

    test('a click with no drag reports the whole-screen shortcut', () {
      final m = _model();
      final wasClick = _drag(m, const Offset(500, 500), const Offset(502, 501));

      expect(wasClick, isTrue);
      expect(m.phase, OverlayPhase.idle);
      expect(m.selection, isNull);
    });

    test('a drag is clamped to the overlay bounds', () {
      final m = _model();
      _drag(m, const Offset(900, 700), const Offset(1400, 1200));
      expect(m.selection, const Rect.fromLTRB(900, 700, 1000, 800));
    });
  });

  group('adjusting a settled selection', () {
    test('a press outside starts a new selection instead of capturing', () {
      // The regression this whole change exists to prevent: with the overlay
      // now sitting open, a stray click must not grab anything.
      final m = _model();
      _drag(m, const Offset(100, 100), const Offset(400, 300));

      final consumed = m.pointerDown(const Offset(700, 600));
      expect(consumed, isFalse);
      expect(m.phase, OverlayPhase.drawing);
    });

    test('a press inside slides the whole selection', () {
      final m = _model();
      _drag(m, const Offset(100, 100), const Offset(400, 300));

      final consumed = m.pointerDown(const Offset(250, 200));
      expect(consumed, isTrue);
      expect(m.phase, OverlayPhase.moving);

      m.pointerMove(const Offset(300, 260));
      expect(m.selection, const Rect.fromLTRB(150, 160, 450, 360));
      expect(
        m.selection!.size,
        const Size(300, 200),
        reason: 'sliding must not resize',
      );

      m.pointerUp();
      expect(m.phase, OverlayPhase.adjusting);
    });

    test('sliding into a wall stops rather than shrinking', () {
      final m = _model();
      _drag(m, const Offset(100, 100), const Offset(400, 300));

      m.pointerDown(const Offset(250, 200));
      m.pointerMove(const Offset(-500, -500));

      expect(m.selection, const Rect.fromLTRB(0, 0, 300, 200));
      expect(m.selection!.size, const Size(300, 200));
    });

    test('a corner grip resizes from that corner', () {
      final m = _model();
      _drag(m, const Offset(100, 100), const Offset(400, 300));

      expect(m.gripAt(const Offset(400, 300)), SelectionGrip.bottomRight);
      m.pointerDown(const Offset(400, 300));
      m.pointerMove(const Offset(500, 350));

      expect(m.selection, const Rect.fromLTRB(100, 100, 500, 350));
    });

    test('an edge grip moves only its own edge', () {
      final m = _model();
      _drag(m, const Offset(100, 100), const Offset(400, 300));

      m.pointerDown(const Offset(100, 200)); // left edge
      m.pointerMove(const Offset(60, 260));

      expect(
        m.selection,
        const Rect.fromLTRB(60, 100, 400, 300),
        reason: 'vertical travel must not move a left-edge grip',
      );
    });

    test('dragging an edge past its opposite flips instead of collapsing', () {
      final m = _model();
      _drag(m, const Offset(100, 100), const Offset(400, 300));

      m.pointerDown(const Offset(400, 200)); // right edge
      m.pointerMove(const Offset(40, 200)); // well past the left edge

      final s = m.selection!;
      expect(s.left, lessThan(s.right));
      expect(s, const Rect.fromLTRB(40, 100, 100, 300));
    });

    test('grips beat the body where they overlap', () {
      final m = _model();
      _drag(m, const Offset(100, 100), const Offset(400, 300));
      // Just inside the corner, which is body *and* grip.
      expect(m.gripAt(const Offset(402, 302)), SelectionGrip.bottomRight);
      expect(m.gripAt(const Offset(250, 200)), SelectionGrip.body);
      expect(m.gripAt(const Offset(700, 700)), isNull);
    });

    test('resizing down to nothing drops the selection', () {
      final m = _model();
      _drag(m, const Offset(100, 100), const Offset(400, 300));

      m.pointerDown(const Offset(400, 300));
      m.pointerMove(const Offset(102, 102));
      m.pointerUp();

      expect(m.phase, OverlayPhase.idle);
      expect(m.selection, isNull);
    });
  });

  group('capture button placement', () {
    const button = Size(120, 30);

    test('sits below the selection when there is room', () {
      final m = _model();
      _drag(m, const Offset(100, 100), const Offset(400, 300));

      final r = m.captureButtonRect(button);
      expect(r.top, 308);
      expect(r.right, 400, reason: 'right-aligned to the selection');
    });

    test('flips above when the selection reaches the bottom', () {
      final m = _model();
      _drag(m, const Offset(100, 600), const Offset(400, 800));

      final r = m.captureButtonRect(button);
      expect(
        r.bottom,
        lessThanOrEqualTo(600),
        reason: 'must clear the selection upward',
      );
    });

    test('stays on screen for a selection that fills the overlay', () {
      final m = _model();
      _drag(m, const Offset(0, 0), const Offset(1000, 800));

      final r = m.captureButtonRect(button);
      expect(r.left, greaterThanOrEqualTo(0));
      expect(r.top, greaterThanOrEqualTo(0));
      expect(r.right, lessThanOrEqualTo(1000));
      expect(r.bottom, lessThanOrEqualTo(800));
    });

    test('is pulled inside rather than off the left edge', () {
      final m = _model();
      _drag(m, const Offset(0, 100), const Offset(60, 300));

      final r = m.captureButtonRect(button);
      expect(r.left, greaterThanOrEqualTo(0));
      expect(r.right, lessThanOrEqualTo(1000));
    });

    test('is empty with no selection', () {
      expect(_model().captureButtonRect(button), Rect.zero);
    });
  });

  group('clearing', () {
    test('drops everything back to idle', () {
      final m = _model();
      _drag(m, const Offset(100, 100), const Offset(400, 300));
      m.clear();

      expect(m.phase, OverlayPhase.idle);
      expect(m.selection, isNull);
      expect(m.showsChrome, isFalse);
      expect(m.hasUsableSelection, isFalse);
    });
  });
}
