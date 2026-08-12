import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../models/annotation.dart';
import '../utils/constants.dart';
import 'tool_handler.dart';

class HighlighterToolHandler extends ToolHandler {
  final _uuid = const Uuid();

  HighlighterToolHandler(super.delegate);

  @override
  void onPanStart(DragStartDetails details, Offset pos) {
    final annotation = Annotation(
      id: _uuid.v4(),
      tool: CanvasTool.highlight,
      color: delegate.activeColor,
      strokeWidth: delegate.strokeWidth,
      opacity: delegate.opacity,
      points: [pos],
    );
    delegate.onCurrentAnnotationChanged(annotation);
  }

  @override
  void onPanUpdate(DragUpdateDetails details, Offset pos) {
    final current = delegate.currentAnnotation;
    if (current != null) {
      final updatedPoints = List<Offset>.from(current.points)..add(pos);
      final updated = current.copyWith(points: updatedPoints);
      delegate.onCurrentAnnotationChanged(updated);
    }
  }

  @override
  void onPanEnd(DragEndDetails details) {
    final current = delegate.currentAnnotation;
    if (current != null && current.points.isNotEmpty) {
      delegate.onAnnotationAdded(current);
    }
    delegate.onCurrentAnnotationChanged(null);
  }

  @override
  void onTapUp(TapUpDetails details, Offset pos) {}
}
