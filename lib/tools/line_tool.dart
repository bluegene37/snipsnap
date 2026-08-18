import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../utils/constants.dart';
import 'tool_handler.dart';

class LineToolHandler extends ToolHandler {
  final _uuid = const Uuid();
  Offset? _drawStart;

  LineToolHandler(super.delegate);

  @override
  void onPanStart(DragStartDetails details, Offset pos) {
    _drawStart = pos;
    final annotation = buildStyledAnnotation(
      id: _uuid.v4(),
      tool: CanvasTool.line,
      startPoint: pos,
      endPoint: pos,
    );
    delegate.onCurrentAnnotationChanged(annotation);
  }

  @override
  void onPanUpdate(DragUpdateDetails details, Offset pos) {
    final current = delegate.currentAnnotation;
    if (current != null && _drawStart != null) {
      var start = _drawStart!;
      var end = pos;

      // Shift-snap to 15-degree angle increments
      if (delegate.isShiftDown) {
        final d = end - start;
        final length = d.distance;
        if (length > 0) {
          final rawAngle = math.atan2(d.dy, d.dx);
          const step = math.pi / 12; // 15 degrees
          final snappedAngle = (rawAngle / step).round() * step;
          end = Offset(
            start.dx + length * math.cos(snappedAngle),
            start.dy + length * math.sin(snappedAngle),
          );
        }
      }

      // Alt/Option draws symmetric line from center
      if (delegate.isAltDown) {
        final half = end - _drawStart!;
        start = _drawStart! - half;
      }

      final updated = current.copyWith(
        startPoint: start,
        endPoint: end,
      );
      delegate.onCurrentAnnotationChanged(updated);
    }
  }

  @override
  void onPanEnd(DragEndDetails details) {
    final current = delegate.currentAnnotation;
    if (current != null && isCommittableDrag(current.startPoint, current.endPoint)) {
      delegate.onAnnotationAdded(current);
      delegate.onSelectedAnnotationIdChanged(current.id);
    }
    delegate.onCurrentAnnotationChanged(null);
    _drawStart = null;
  }

  @override
  void onTapUp(TapUpDetails details, Offset pos) {}
}
