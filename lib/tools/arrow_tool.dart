import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../models/annotation.dart';
import '../utils/constants.dart';
import 'tool_handler.dart';

class ArrowToolHandler extends ToolHandler {
  final _uuid = const Uuid();

  ArrowToolHandler(super.delegate);

  @override
  void onPanStart(DragStartDetails details, Offset pos) {
    final annotation = Annotation(
      id: _uuid.v4(),
      tool: CanvasTool.arrow,
      color: delegate.activeColor,
      strokeWidth: delegate.strokeWidth,
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
      if ((current.endPoint! - current.startPoint!).distance > 3) {
        delegate.onAnnotationAdded(current);
      }
    }
    delegate.onCurrentAnnotationChanged(null);
  }

  @override
  void onTapUp(TapUpDetails details, Offset pos) {}
}
