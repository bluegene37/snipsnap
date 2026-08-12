import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../models/annotation.dart';
import '../utils/constants.dart';
import 'tool_handler.dart';

class ShapeToolHandler extends ToolHandler {
  final CanvasTool toolType;
  final Uuid _uuid = const Uuid();

  ShapeToolHandler(super.delegate, this.toolType);

  @override
  void onPanStart(DragStartDetails details, Offset pos) {
    final annotation = Annotation(
      id: _uuid.v4(),
      tool: toolType,
      color: delegate.activeColor,
      strokeWidth: delegate.strokeWidth,
      opacity: delegate.opacity,
      startPoint: pos,
      endPoint: pos,
      fill: delegate.isFilled,
    );
    
    delegate.onCurrentAnnotationChanged(annotation);
  }

  @override
  void onPanUpdate(DragUpdateDetails details, Offset pos) {
    if (delegate.currentAnnotation != null) {
      final updated = delegate.currentAnnotation!.copyWith(endPoint: pos);
      delegate.onCurrentAnnotationChanged(updated);
    }
  }

  @override
  void onPanEnd(DragEndDetails details) {
    if (delegate.currentAnnotation != null) {
      delegate.onAnnotationAdded(delegate.currentAnnotation!);
      delegate.onCurrentAnnotationChanged(null);
      delegate.onToolSelected(CanvasTool.select);
    }
  }

  @override
  void onTapUp(TapUpDetails details, Offset pos) {
    delegate.onToolSelected(CanvasTool.select);
  }
}
