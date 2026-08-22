import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../utils/snip_theme.dart';

/// Opens the app's custom colour picker.
///
/// [onColorChanged] fires live as the user drags, so the canvas and the
/// properties panel track the picker without waiting for Done. [onSaveColor],
/// when supplied, adds a "Save Color" action that hands back the colour shown
/// at that moment.
///
/// Replaces `flutter_colorpicker`'s `ColorPicker`, which cannot be used here:
/// every painter in that package returns `false` from `shouldRepaint`, so its
/// gradient and its position indicator never redraw once the widget is first
/// painted. The colour value updated correctly while the thumb sat frozen
/// where it started — the "picker is not reactive" bug. Owning the widget is
/// the only fix; the package has had no release since 2022.
Future<void> showSnipColorPicker({
  required BuildContext context,
  required String title,
  required Color initialColor,
  required ValueChanged<Color> onColorChanged,
  ValueChanged<Color>? onSaveColor,
}) {
  final t = SnipTheme.of(context);
  var current = initialColor;

  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: t.surfaceRaised,
      title: Text(title, style: TextStyle(color: t.ink, fontSize: 16, fontWeight: FontWeight.bold)),
      content: SnipColorPicker(
        initialColor: initialColor,
        onColorChanged: (c) {
          current = c;
          onColorChanged(c);
        },
      ),
      actions: [
        if (onSaveColor != null)
          TextButton.icon(
            icon: Icon(Icons.bookmark_add_outlined, size: 16, color: t.ink),
            label: Text('Save Color',
                style: TextStyle(color: t.ink, fontWeight: FontWeight.w600)),
            onPressed: () => onSaveColor(current),
          ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text('Done', style: TextStyle(color: t.emphasis, fontWeight: FontWeight.bold)),
        ),
      ],
    ),
  );
}

/// Saturation/value field + hue rail + alpha rail + hex entry, all driven from
/// one [HSVColor] held in this State so every part redraws together.
class SnipColorPicker extends StatefulWidget {
  final Color initialColor;
  final ValueChanged<Color> onColorChanged;

  /// Width of the picker body. The saturation/value field is square-ish at
  /// this width; the dialog sizes itself around it.
  final double width;

  const SnipColorPicker({
    super.key,
    required this.initialColor,
    required this.onColorChanged,
    this.width = 280,
  });

  @override
  State<SnipColorPicker> createState() => _SnipColorPickerState();
}

class _SnipColorPickerState extends State<SnipColorPicker> {
  late HSVColor _hsv;
  late final TextEditingController _hexController;

  /// True while the hex field is being edited by hand, so echoing the parsed
  /// colour back into the controller does not fight the user's caret.
  bool _editingHex = false;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.initialColor);
    // Hue is undefined for greys, and `HSVColor.fromColor` reports 0 for them.
    // That is fine as a starting point; the rail simply begins at red.
    _hexController = TextEditingController(text: _hexOf(widget.initialColor));
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  static String _hexOf(Color c) =>
      '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

  void _emit(HSVColor next) {
    setState(() => _hsv = next);
    final color = next.toColor();
    if (!_editingHex) _hexController.text = _hexOf(color);
    widget.onColorChanged(color);
  }

  void _applyHexInput(String raw) {
    var text = raw.trim().replaceFirst('#', '');
    if (text.length == 3) {
      text = text.split('').map((ch) => '$ch$ch').join();
    }
    if (text.length == 6) text = 'FF$text';
    if (text.length != 8) return;
    final value = int.tryParse(text, radix: 16);
    if (value == null) return;
    final color = Color(value);
    setState(() => _hsv = HSVColor.fromColor(color).withAlpha(_hsv.alpha));
    widget.onColorChanged(color.withValues(alpha: _hsv.alpha));
  }

  @override
  Widget build(BuildContext context) {
    final t = SnipTheme.of(context);
    final color = _hsv.toColor();
    final fieldHeight = widget.width * 0.62;

    return SizedBox(
      width: widget.width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Saturation (x) / value (y) field.
          ClipRRect(
            borderRadius: BorderRadius.circular(t.radius),
            child: _PickerSurface(
              onPointer: (local, size) {
                final s = (local.dx / size.width).clamp(0.0, 1.0);
                final v = 1 - (local.dy / size.height).clamp(0.0, 1.0);
                _emit(_hsv.withSaturation(s).withValue(v));
              },
              child: CustomPaint(
                size: Size(widget.width, fieldHeight),
                painter: _SaturationValuePainter(_hsv),
              ),
            ),
          ),
          const SizedBox(height: 14),

          // Hue rail.
          _PickerSurface(
            onPointer: (local, size) {
              final hue = (local.dx / size.width).clamp(0.0, 1.0) * 360;
              _emit(_hsv.withHue(hue));
            },
            child: ClipRRect(
              borderRadius: BorderRadius.circular(7),
              child: CustomPaint(
                size: Size(widget.width, 14),
                painter: _HueRailPainter(_hsv),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Alpha rail, over a checkerboard so full transparency is readable.
          _PickerSurface(
            onPointer: (local, size) {
              final alpha = (local.dx / size.width).clamp(0.0, 1.0);
              _emit(_hsv.withAlpha(alpha));
            },
            child: ClipRRect(
              borderRadius: BorderRadius.circular(7),
              child: CustomPaint(
                size: Size(widget.width, 14),
                painter: _AlphaRailPainter(_hsv),
              ),
            ),
          ),
          const SizedBox(height: 14),

          // Preview + hex entry.
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(t.radius),
                  border: Border.all(color: t.border, width: t.hairline),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(t.radius),
                  child: CustomPaint(
                    painter: const CheckerboardPainter(),
                    child: Container(color: color),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _hexController,
                  style: TextStyle(color: t.ink, fontSize: 13, fontWeight: FontWeight.w600),
                  inputFormatters: [
                    LengthLimitingTextInputFormatter(9),
                    FilteringTextInputFormatter.allow(RegExp(r'[#0-9a-fA-F]')),
                  ],
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: 'Hex',
                    labelStyle: TextStyle(color: t.inkMuted, fontSize: 12),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(t.radius),
                      borderSide: BorderSide(color: t.border, width: t.hairline),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(t.radius),
                      borderSide: BorderSide(color: t.borderStrong, width: t.hairline),
                    ),
                  ),
                  onTap: () => _editingHex = true,
                  onChanged: (value) {
                    _editingHex = true;
                    _applyHexInput(value);
                  },
                  onEditingComplete: () {
                    _editingHex = false;
                    _hexController.text = _hexOf(_hsv.toColor());
                    FocusScope.of(context).unfocus();
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Wraps [child] in a drag-and-tap surface that reports the local position and
/// the surface's own size.
///
/// Uses a raw recogniser that always accepts, because the picker sits inside a
/// dialog whose content can scroll: an ordinary `PanGestureRecognizer` loses
/// the vertical drag to the scroll view and the saturation/value field stops
/// responding halfway through the gesture.
class _PickerSurface extends StatelessWidget {
  final void Function(Offset local, Size size) onPointer;
  final Widget child;

  const _PickerSurface({required this.onPointer, required this.child});

  void _handle(BuildContext context, Offset global) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    onPointer(box.globalToLocal(global), box.size);
  }

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (inner) => RawGestureDetector(
        gestures: {
          _EagerPanRecognizer: GestureRecognizerFactoryWithHandlers<_EagerPanRecognizer>(
            _EagerPanRecognizer.new,
            (instance) => instance
              ..onDown = ((d) => _handle(inner, d.globalPosition))
              ..onUpdate = ((d) => _handle(inner, d.globalPosition)),
          ),
        },
        child: child,
      ),
    );
  }
}

/// A pan recogniser that claims the gesture arena immediately, so a picker rail
/// inside a scrollable dialog keeps the drag instead of handing it to the
/// scroll view.
class _EagerPanRecognizer extends PanGestureRecognizer {
  @override
  void rejectGesture(int pointer) => acceptGesture(pointer);
}

/// The saturation/value field for the current hue, plus the position ring.
class _SaturationValuePainter extends CustomPainter {
  final HSVColor hsv;

  const _SaturationValuePainter(this.hsv);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // White -> full hue horizontally, transparent -> black vertically.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [
            const Color(0xFFFFFFFF),
            HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor(),
          ],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Color(0xFF000000)],
        ).createShader(rect),
    );

    _drawThumb(
      canvas,
      Offset(size.width * hsv.saturation, size.height * (1 - hsv.value)),
      HSVColor.fromAHSV(1, hsv.hue, hsv.saturation, hsv.value).toColor(),
    );
  }

  @override
  bool shouldRepaint(_SaturationValuePainter oldDelegate) => oldDelegate.hsv != hsv;
}

/// The 0-360° hue rail with its position ring.
class _HueRailPainter extends CustomPainter {
  final HSVColor hsv;

  const _HueRailPainter(this.hsv);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [
            for (var i = 0; i <= 6; i++) HSVColor.fromAHSV(1, i * 60.0 % 360, 1, 1).toColor(),
          ],
        ).createShader(rect),
    );
    _drawThumb(
      canvas,
      Offset(size.width * (hsv.hue / 360), size.height / 2),
      HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor(),
      radius: size.height / 2 - 1,
    );
  }

  @override
  bool shouldRepaint(_HueRailPainter oldDelegate) => oldDelegate.hsv.hue != hsv.hue;
}

/// The transparent -> opaque rail for the current hue, over a checkerboard.
class _AlphaRailPainter extends CustomPainter {
  final HSVColor hsv;

  const _AlphaRailPainter(this.hsv);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    paintCheckerboard(canvas, size);
    final opaque = HSVColor.fromAHSV(1, hsv.hue, hsv.saturation, hsv.value).toColor();
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [opaque.withValues(alpha: 0), opaque],
        ).createShader(rect),
    );
    _drawThumb(canvas, Offset(size.width * hsv.alpha, size.height / 2), opaque,
        radius: size.height / 2 - 1);
  }

  @override
  bool shouldRepaint(_AlphaRailPainter oldDelegate) => oldDelegate.hsv != hsv;
}

/// The position ring, drawn as a black hairline inside a white one so it stays
/// visible over any part of the gradient it lands on.
void _drawThumb(Canvas canvas, Offset center, Color under, {double radius = 8}) {
  canvas.drawCircle(
    center,
    radius,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = const Color(0xFFFFFFFF),
  );
  canvas.drawCircle(
    center,
    radius,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = const Color(0xFF000000),
  );
}

/// The neutral transparency checkerboard. Mode-invariant on purpose, exactly
/// like [SnipTheme.scrim]: it stands for "no pixels here", which is a property
/// of the colour rather than of the chrome around it, and flipping it per mode
/// would make the same transparent colour read as two different things.
void paintCheckerboard(Canvas canvas, Size size) {
  const cell = 6.0;
  final light = Paint()..color = const Color(0xFFE5E5EA);
  final dark = Paint()..color = const Color(0xFF8E8E93);
  var row = 0;
  for (var y = 0.0; y < size.height; y += cell) {
    var col = 0;
    for (var x = 0.0; x < size.width; x += cell) {
      canvas.drawRect(
        Rect.fromLTWH(x, y, math.min(cell, size.width - x), math.min(cell, size.height - y)),
        (row + col) % 2 == 0 ? light : dark,
      );
      col++;
    }
    row++;
  }
}

/// Paints [paintCheckerboard] as a `CustomPaint` background.
class CheckerboardPainter extends CustomPainter {
  const CheckerboardPainter();

  @override
  void paint(Canvas canvas, Size size) => paintCheckerboard(canvas, size);

  @override
  bool shouldRepaint(CheckerboardPainter oldDelegate) => false;
}
