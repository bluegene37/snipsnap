import 'dart:ui';

/// Which part of a settled selection a pointer landed on.
enum SelectionGrip {
  topLeft,
  top,
  topRight,
  right,
  bottomRight,
  bottom,
  bottomLeft,
  left,

  /// The interior — grabbing here slides the whole selection.
  body,
}

/// What the capture overlay is currently doing.
enum OverlayPhase {
  /// Nothing selected yet. Dragging starts a new selection.
  idle,

  /// Rubber-banding a new selection.
  drawing,

  /// A selection exists and is waiting to be confirmed. Nothing has been
  /// captured yet, and the overlay sits here indefinitely.
  adjusting,

  /// Sliding the whole selection.
  moving,

  /// Dragging one grip.
  resizing,
}

/// Geometry and state for the capture overlay's selection, with no dependency
/// on how it is drawn or which window hosts it.
///
/// The capture used to fire the instant the drag ended, so the region you got
/// was whatever you happened to release on. Releasing now settles the selection
/// and the overlay waits — which turns a one-shot gesture into a small state
/// machine, and that machine is what this class is. Keeping it free of Flutter
/// widgets is what lets the same rules run on macOS, Windows and Linux and
/// still be tested without a screen.
///
/// All coordinates are logical pixels in the overlay's own space, y growing
/// downward, as everywhere else in Flutter.
class CaptureSelectionModel {
  CaptureSelectionModel({
    required this.bounds,
    this.minSide = 8.0,
    double? gripSize,
  }) : gripSize = gripSize ?? 12.0;

  /// The full overlay area. Selections are clamped to it.
  final Rect bounds;

  /// Below this on either axis a selection is treated as an accidental click
  /// rather than a region.
  final double minSide;

  /// Side length of a grip's hit target.
  final double gripSize;

  OverlayPhase _phase = OverlayPhase.idle;
  Rect? _selection;

  Offset _dragOrigin = Offset.zero;
  Rect _selectionAtDragStart = Rect.zero;
  SelectionGrip? _activeGrip;

  OverlayPhase get phase => _phase;
  Rect? get selection => _selection;
  SelectionGrip? get activeGrip => _activeGrip;

  /// True once there is a selection worth capturing.
  bool get hasUsableSelection {
    final s = _selection;
    return s != null && s.width >= minSide && s.height >= minSide;
  }

  /// True when the selection has settled and the confirm affordances belong on
  /// screen. Deliberately includes the in-flight move and resize, so the grips
  /// and button do not blink out from under the pointer mid-drag.
  bool get showsChrome =>
      _phase == OverlayPhase.adjusting ||
      _phase == OverlayPhase.moving ||
      _phase == OverlayPhase.resizing;

  /// Hit targets for each grip, centred on the selection's corners and edges.
  Map<SelectionGrip, Rect> gripTargets() {
    final s = _selection;
    if (s == null) return const {};
    final h = gripSize / 2;
    Rect box(double cx, double cy) =>
        Rect.fromLTWH(cx - h, cy - h, gripSize, gripSize);

    return {
      SelectionGrip.topLeft: box(s.left, s.top),
      SelectionGrip.top: box(s.center.dx, s.top),
      SelectionGrip.topRight: box(s.right, s.top),
      SelectionGrip.right: box(s.right, s.center.dy),
      SelectionGrip.bottomRight: box(s.right, s.bottom),
      SelectionGrip.bottom: box(s.center.dx, s.bottom),
      SelectionGrip.bottomLeft: box(s.left, s.bottom),
      SelectionGrip.left: box(s.left, s.center.dy),
    };
  }

  /// Which part of the selection [point] is over, or null if it is outside.
  ///
  /// Grips win over the body: they overlap it, and a pointer on a corner means
  /// to resize.
  SelectionGrip? gripAt(Offset point) {
    final s = _selection;
    if (s == null) return null;
    for (final entry in gripTargets().entries) {
      if (entry.value.inflate(2).contains(point)) return entry.key;
    }
    return s.contains(point) ? SelectionGrip.body : null;
  }

  // ---------------------------------------------------------------------------
  // Pointer
  // ---------------------------------------------------------------------------

  /// Returns true when the press was consumed by an existing selection, which
  /// the caller needs in order to tell "adjusting the region" from "starting a
  /// new one".
  bool pointerDown(Offset point) {
    _dragOrigin = point;

    if (showsChrome && _selection != null) {
      final grip = gripAt(point);
      if (grip != null) {
        _selectionAtDragStart = _selection!;
        _activeGrip = grip;
        _phase = grip == SelectionGrip.body
            ? OverlayPhase.moving
            : OverlayPhase.resizing;
        return true;
      }
    }

    // Outside an existing selection, or nothing selected yet: start over.
    _activeGrip = null;
    _selection = Rect.fromPoints(point, point);
    _phase = OverlayPhase.drawing;
    return false;
  }

  void pointerMove(Offset point) {
    final delta = point - _dragOrigin;
    switch (_phase) {
      case OverlayPhase.drawing:
        _selection = _clamp(Rect.fromPoints(_dragOrigin, point));
      case OverlayPhase.moving:
        _selection = _slide(_selectionAtDragStart, delta);
      case OverlayPhase.resizing:
        _selection = _resize(_selectionAtDragStart, _activeGrip!, delta);
      case OverlayPhase.idle:
      case OverlayPhase.adjusting:
        return;
    }
  }

  /// Ends the current drag.
  ///
  /// Returns true when the gesture was a click rather than a drag — no usable
  /// region — which the caller treats as "capture the whole screen", the
  /// shortcut this overlay has always had. That is the one path that skips the
  /// confirm, and only from [OverlayPhase.idle]: once a selection exists, a
  /// click outside it starts a new one instead, so a stray click can no longer
  /// grab the whole desktop by accident.
  bool pointerUp() {
    switch (_phase) {
      case OverlayPhase.drawing:
        if (!hasUsableSelection) {
          _selection = null;
          _phase = OverlayPhase.idle;
          _activeGrip = null;
          return true;
        }
        _phase = OverlayPhase.adjusting;
        _activeGrip = null;
        return false;

      case OverlayPhase.moving:
      case OverlayPhase.resizing:
        _phase = hasUsableSelection
            ? OverlayPhase.adjusting
            : OverlayPhase.idle;
        if (_phase == OverlayPhase.idle) _selection = null;
        _activeGrip = null;
        return false;

      case OverlayPhase.idle:
      case OverlayPhase.adjusting:
        return false;
    }
  }

  /// Drops the selection without capturing.
  void clear() {
    _selection = null;
    _phase = OverlayPhase.idle;
    _activeGrip = null;
  }

  // ---------------------------------------------------------------------------
  // Geometry
  // ---------------------------------------------------------------------------

  Rect _clamp(Rect rect) {
    final r = rect.intersect(bounds);
    if (r.width < 0 || r.height < 0) return Rect.zero;
    return r;
  }

  /// Moves [rect] by [delta], stopping at the overlay edges rather than
  /// shrinking — a selection pushed against a wall keeps its size.
  Rect _slide(Rect rect, Offset delta) {
    var r = rect.shift(delta);
    if (r.left < bounds.left) r = r.shift(Offset(bounds.left - r.left, 0));
    if (r.top < bounds.top) r = r.shift(Offset(0, bounds.top - r.top));
    if (r.right > bounds.right) r = r.shift(Offset(bounds.right - r.right, 0));
    if (r.bottom > bounds.bottom) {
      r = r.shift(Offset(0, bounds.bottom - r.bottom));
    }
    return r;
  }

  /// Resizes [rect] by dragging [grip].
  ///
  /// The result is normalised, so dragging an edge past its opposite flips the
  /// selection instead of collapsing it to nothing.
  Rect _resize(Rect rect, SelectionGrip grip, Offset delta) {
    var left = rect.left;
    var top = rect.top;
    var right = rect.right;
    var bottom = rect.bottom;

    switch (grip) {
      case SelectionGrip.left:
      case SelectionGrip.topLeft:
      case SelectionGrip.bottomLeft:
        left += delta.dx;
      case SelectionGrip.right:
      case SelectionGrip.topRight:
      case SelectionGrip.bottomRight:
        right += delta.dx;
      case SelectionGrip.top:
      case SelectionGrip.bottom:
      case SelectionGrip.body:
        break;
    }
    switch (grip) {
      case SelectionGrip.top:
      case SelectionGrip.topLeft:
      case SelectionGrip.topRight:
        top += delta.dy;
      case SelectionGrip.bottom:
      case SelectionGrip.bottomLeft:
      case SelectionGrip.bottomRight:
        bottom += delta.dy;
      case SelectionGrip.left:
      case SelectionGrip.right:
      case SelectionGrip.body:
        break;
    }

    return _clamp(
      Rect.fromLTRB(
        left < right ? left : right,
        top < bottom ? top : bottom,
        left < right ? right : left,
        top < bottom ? bottom : top,
      ),
    );
  }

  /// Where the Capture button belongs for the current selection.
  ///
  /// Below the selection by preference, above it when that would run off the
  /// bottom, and pulled inside when the selection reaches both edges — so the
  /// button is always reachable and never sits over the region being captured
  /// unless there is nowhere else for it to go.
  Rect captureButtonRect(Size buttonSize, {double margin = 8.0}) {
    final s = _selection;
    if (s == null) return Rect.zero;

    var top = s.bottom + margin;
    if (top + buttonSize.height > bounds.bottom - 4) {
      top = s.top - buttonSize.height - margin;
    }
    if (top < bounds.top + 4) {
      top = (s.bottom - buttonSize.height - margin).clamp(
        bounds.top + 4,
        bounds.bottom - buttonSize.height - 4,
      );
    }

    var left = s.right - buttonSize.width;
    if (left < bounds.left + 4) left = bounds.left + 4;
    if (left + buttonSize.width > bounds.right - 4) {
      left = bounds.right - buttonSize.width - 4;
    }

    return Rect.fromLTWH(left, top, buttonSize.width, buttonSize.height);
  }
}
