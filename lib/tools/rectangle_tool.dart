import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../models/annotation.dart';
import '../utils/constants.dart';
import 'tool_handler.dart';

class RectangleToolHandler extends ToolHandler {
  final _uuid = const Uuid();

  RectangleToolHandler(super.delegate);

  @override
  void onPanStart(DragStartDetails details, Offset pos) {
    final annotation = Annotation(
      id: _uuid.v4(),
      tool: CanvasTool.rectangle,
      color: delegate.activeColor,
      strokeWidth: delegate.strokeWidth,
      fill: delegate.isFilled,
      opacity: delegate.opacity,
      startPoint: pos,
      endPoint: pos,
    );
    delegate.onCurrentAnnotationChanged(annotation);
  }

  @override
  void onPanUpdate(DragUpdateDetails details, Offset pos) {
    final current = delegate.currentAnnotation;
    if (current != null) {
      final updated = current.copyWith(endPoint: pos);
      delegate.onCurrentAnnotationChanged(updated);
    }
  }

  @override
  void onPanEnd(DragEndDetails details) {
    final current = delegate.currentAnnotation;
    if (current != null && current.startPoint != null && current.endPoint != null) {
      final rect = Rect.fromPoints(current.startPoint!, current.endPoint!);
      if (rect.width > 3 && rect.height > 3) {
        delegate.onAnnotationAdded(current);
      }
    }
    delegate.onCurrentAnnotationChanged(null);
  }

  @override
  void onTapUp(TapUpDetails details, Offset pos) {}
}
