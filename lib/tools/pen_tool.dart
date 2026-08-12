import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../models/annotation.dart';
import '../utils/constants.dart';
import 'tool_handler.dart';

class PenToolHandler extends ToolHandler {
  final CanvasTool toolType;
  final Uuid _uuid = const Uuid();
  List<Offset> _currentPoints = [];

  PenToolHandler(super.delegate, this.toolType);

  @override
  void onPanStart(DragStartDetails details, Offset pos) {
    _currentPoints = [pos];
    final annotation = Annotation(
      id: _uuid.v4(),
      tool: toolType,
      color: delegate.activeColor,
      strokeWidth: delegate.strokeWidth,
      opacity: delegate.opacity,
      points: _currentPoints,
    );
    delegate.onCurrentAnnotationChanged(annotation);
  }

  @override
  void onPanUpdate(DragUpdateDetails details, Offset pos) {
    if (delegate.currentAnnotation != null) {
      _currentPoints.add(pos);
      final updated = delegate.currentAnnotation!.copyWith(points: _currentPoints);
      delegate.onCurrentAnnotationChanged(updated);
    }
  }

  @override
  void onPanEnd(DragEndDetails details) {
    if (delegate.currentAnnotation != null) {
      delegate.onAnnotationAdded(delegate.currentAnnotation!);
      delegate.onCurrentAnnotationChanged(null);
      _currentPoints = [];
      delegate.onToolSelected(CanvasTool.select);
    }
  }

  @override
  void onTapUp(TapUpDetails details, Offset pos) {
    delegate.onToolSelected(CanvasTool.select);
  }
}
