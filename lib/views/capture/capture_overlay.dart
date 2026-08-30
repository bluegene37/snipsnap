import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'capture_selection.dart';

/// Coffee, not the stock system blue.
///
/// The wash over the desktop is warm rather than neutral black, which reads as
/// a tint rather than a grey veil. The selection itself is knocked clear, so
/// the region actually being captured always shows its true colours — the
/// palette never lies about what you are about to grab.
class CaptureColors {
  const CaptureColors._();

  /// Roasted brown: selection outline, grip strokes, Capture button.
  static const Color coffee = Color(0xFF6F4E37);

  /// The lighter tone the button lifts to on hover.
  static const Color crema = Color(0xFFC8A27A);

  /// Warm espresso wash over everything outside the selection.
  static const Color backdrop = Color(0x6B211710);

  /// Near-black bean for the dimension badge.
  static const Color bean = Color(0xE01C1310);
}

/// Full-screen region picker.
///
/// Releasing the drag settles the selection instead of capturing it: the
/// region stays put with grips on every corner and edge and a Capture button
/// beside it, and nothing is grabbed until that button is pressed (or Return).
/// Escape cancels.
///
/// Written in Flutter rather than per-platform so macOS, Windows and Linux get
/// the same overlay from one implementation — the interaction rules live in
/// [CaptureSelectionModel], which is tested without a screen.
class CaptureOverlay extends StatefulWidget {
  const CaptureOverlay({
    super.key,
    required this.onCapture,
    required this.onCancel,
    this.background,
    this.devicePixelRatio = 1.0,
  });

  /// The chosen region, in the overlay's logical coordinates. The caller maps
  /// it onto the screen bitmap.
  final ValueChanged<Rect> onCapture;

  final VoidCallback onCancel;

  /// Pre-captured screen bitmap shown beneath the wash. Null renders the
  /// overlay transparent, for a window that already shows the live desktop.
  final ui.Image? background;

  /// Used only for the `1234 × 567 px` readout, so it reports real pixels
  /// rather than logical ones.
  final double devicePixelRatio;

  @override
  State<CaptureOverlay> createState() => _CaptureOverlayState();
}

class _CaptureOverlayState extends State<CaptureOverlay> {
  CaptureSelectionModel? _model;
  Size _lastSize = Size.zero;
  final FocusNode _focusNode = FocusNode();

  static const Size _buttonSize = Size(122, 34);

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  /// The model is rebuilt when the overlay is resized — a display change or a
  /// window move — because every rule in it is expressed against the bounds.
  CaptureSelectionModel _modelFor(Size size) {
    final existing = _model;
    if (existing != null && size == _lastSize) return existing;
    _lastSize = size;
    final next = CaptureSelectionModel(bounds: Offset.zero & size);
    _model = next;
    return next;
  }

  void _confirm() {
    final m = _model;
    if (m == null || !m.hasUsableSelection) return;
    widget.onCapture(m.selection!);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      widget.onCancel();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      _confirm();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  MouseCursor _cursorFor(CaptureSelectionModel m, Offset point) {
    if (!m.showsChrome) return SystemMouseCursors.precise;
    return switch (m.gripAt(point)) {
      SelectionGrip.left ||
      SelectionGrip.right => SystemMouseCursors.resizeLeftRight,
      SelectionGrip.top ||
      SelectionGrip.bottom => SystemMouseCursors.resizeUpDown,
      SelectionGrip.topLeft ||
      SelectionGrip.bottomRight => SystemMouseCursors.resizeUpLeftDownRight,
      SelectionGrip.topRight ||
      SelectionGrip.bottomLeft => SystemMouseCursors.resizeUpRightDownLeft,
      SelectionGrip.body => SystemMouseCursors.move,
      null => SystemMouseCursors.precise,
    };
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKey,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final model = _modelFor(size);
          final buttonRect = model.showsChrome
              ? model.captureButtonRect(_buttonSize)
              : Rect.zero;

          return Stack(
            children: [
              Positioned.fill(
                child: Listener(
                  onPointerDown: (e) =>
                      setState(() => model.pointerDown(e.localPosition)),
                  onPointerMove: (e) =>
                      setState(() => model.pointerMove(e.localPosition)),
                  onPointerUp: (e) {
                    final wasClick = model.pointerUp();
                    // A click with no drag means the whole screen, the
                    // shortcut this overlay has always had.
                    if (wasClick) {
                      widget.onCapture(Offset.zero & size);
                      return;
                    }
                    setState(() {});
                  },
                  child: _CursorLayer(
                    resolve: (point) => _cursorFor(model, point),
                    child: CustomPaint(
                      painter: _CaptureOverlayPainter(
                        selection:
                            model.showsChrome ||
                                model.phase == OverlayPhase.drawing
                            ? model.selection
                            : null,
                        grips: model.showsChrome
                            ? model.gripTargets().values.toList()
                            : const [],
                        background: widget.background,
                        devicePixelRatio: widget.devicePixelRatio,
                      ),
                      size: Size.infinite,
                    ),
                  ),
                ),
              ),

              if (!buttonRect.isEmpty)
                Positioned(
                  left: buttonRect.left,
                  top: buttonRect.top,
                  width: buttonRect.width,
                  height: buttonRect.height,
                  child: _CaptureButton(onPressed: _confirm),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Tracks the pointer purely to resolve the cursor, so grips advertise what
/// they do before you press.
class _CursorLayer extends StatefulWidget {
  const _CursorLayer({required this.resolve, required this.child});

  final MouseCursor Function(Offset) resolve;
  final Widget child;

  @override
  State<_CursorLayer> createState() => _CursorLayerState();
}

class _CursorLayerState extends State<_CursorLayer> {
  MouseCursor _cursor = SystemMouseCursors.precise;

  void _update(Offset point) {
    final next = widget.resolve(point);
    if (next != _cursor) setState(() => _cursor = next);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: _cursor,
      onHover: (e) => _update(e.localPosition),
      child: widget.child,
    );
  }
}

class _CaptureButton extends StatefulWidget {
  const _CaptureButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<_CaptureButton> createState() => _CaptureButtonState();
}

class _CaptureButtonState extends State<_CaptureButton> {
  bool _hot = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hot = true),
      onExit: (_) => setState(() => _hot = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _hot
                ? Color.lerp(CaptureColors.coffee, CaptureColors.crema, 0.35)
                : CaptureColors.coffee,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: Colors.white.withValues(alpha: 0.35)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x55000000),
                blurRadius: 10,
                offset: Offset(0, 3),
              ),
            ],
          ),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.photo_camera_rounded, size: 16, color: Colors.white),
              SizedBox(width: 7),
              Text(
                'Capture',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CaptureOverlayPainter extends CustomPainter {
  _CaptureOverlayPainter({
    required this.selection,
    required this.grips,
    required this.background,
    required this.devicePixelRatio,
  });

  final Rect? selection;
  final List<Rect> grips;
  final ui.Image? background;
  final double devicePixelRatio;

  @override
  void paint(Canvas canvas, Size size) {
    final full = Offset.zero & size;

    final bg = background;
    if (bg != null) {
      canvas.drawImageRect(
        bg,
        Rect.fromLTWH(0, 0, bg.width.toDouble(), bg.height.toDouble()),
        full,
        Paint()..filterQuality = FilterQuality.medium,
      );
    }

    final sel = selection;

    // The wash, with the selection knocked out of it. evenOdd rather than two
    // draws so the hole is exact at any zoom and the edge stays crisp.
    final wash = Path()..addRect(full);
    if (sel != null && !sel.isEmpty) wash.addRect(sel);
    wash.fillType = PathFillType.evenOdd;
    canvas.drawPath(wash, Paint()..color = CaptureColors.backdrop);

    if (sel == null || sel.isEmpty) return;

    canvas.drawRect(
      sel,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white,
    );
    canvas.drawRect(
      sel.deflate(1),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..color = CaptureColors.coffee,
    );

    for (final grip in grips) {
      final rrect = RRect.fromRectAndRadius(
        grip.deflate(1),
        const Radius.circular(2),
      );
      canvas.drawRRect(rrect, Paint()..color = Colors.white);
      canvas.drawRRect(
        rrect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = CaptureColors.coffee,
      );
    }

    _paintDimensions(canvas, size, sel);
  }

  void _paintDimensions(Canvas canvas, Size size, Rect sel) {
    if (sel.width <= 40 || sel.height <= 25) return;

    final w = (sel.width * devicePixelRatio).round();
    final h = (sel.height * devicePixelRatio).round();
    final painter = TextPainter(
      text: TextSpan(
        text: '$w × $h px',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    const padH = 7.0;
    const padV = 3.0;
    final badgeW = painter.width + padH * 2;
    final badgeH = painter.height + padV * 2;

    // Above the selection, dropping inside when it reaches the top edge.
    var top = sel.top - badgeH - 6;
    if (top < 4) top = sel.top + 6;
    var left = sel.left;
    if (left + badgeW > size.width - 4) left = size.width - badgeW - 4;
    if (left < 4) left = 4;

    final badge = Rect.fromLTWH(left, top, badgeW, badgeH);
    canvas.drawRRect(
      RRect.fromRectAndRadius(badge, const Radius.circular(4)),
      Paint()..color = CaptureColors.bean,
    );
    painter.paint(canvas, Offset(left + padH, top + padV));
  }

  @override
  bool shouldRepaint(covariant _CaptureOverlayPainter old) =>
      old.selection != selection ||
      old.background != background ||
      old.devicePixelRatio != devicePixelRatio ||
      old.grips.length != grips.length ||
      !_sameGrips(old.grips, grips);

  static bool _sameGrips(List<Rect> a, List<Rect> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
