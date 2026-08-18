import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../utils/constants.dart';
import 'tool_handler.dart';

class BlurToolHandler extends ToolHandler {
  final _uuid = const Uuid();
  Offset? _drawStart;

  BlurToolHandler(super.delegate);

  @override
  void onPanStart(DragStartDetails details, Offset pos) {
    _drawStart = pos;
    final annotation = buildStyledAnnotation(
      id: _uuid.v4(),
      tool: CanvasTool.blur,
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

      if (delegate.isShiftDown) {
        final dx = end.dx - start.dx;
        final dy = end.dy - start.dy;
        final size = math.max(dx.abs(), dy.abs());
        end = Offset(
          start.dx + size * (dx >= 0 ? 1 : -1),
          start.dy + size * (dy >= 0 ? 1 : -1),
        );
      }

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
