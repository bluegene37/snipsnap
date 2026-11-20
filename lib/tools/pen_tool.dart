import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../utils/constants.dart';
import 'tool_handler.dart';

class PenToolHandler extends ToolHandler {
  final CanvasTool toolType;
  final Uuid _uuid = const Uuid();
  List<Offset> _currentPoints = [];

  PenToolHandler(super.delegate, [this.toolType = CanvasTool.pen]);

  @override
  void onPanStart(DragStartDetails details, Offset pos) {
    _currentPoints = [pos];
    final annotation = buildStyledAnnotation(
      id: _uuid.v4(),
      tool: toolType,
      startPoint: pos,
      points: _currentPoints,
    );
    delegate.onCurrentAnnotationChanged(annotation);
  }

  @override
  void onPanUpdate(DragUpdateDetails details, Offset pos) {
    final current = delegate.currentAnnotation;
    if (current != null) {
      // Gene - Nov, 20, 2026: Divide stroke sample spacing by viewScale for smooth curves when zoomed in.
      // Old:
      // if (_currentPoints.isEmpty ||
      //     (pos - _currentPoints.last).distance >= 1.5) {
      final s = delegate.viewScale > 0 ? delegate.viewScale : 1.0;
      if (_currentPoints.isEmpty ||
          (pos - _currentPoints.last).distance >= 1.5 / s) {
        _currentPoints = [..._currentPoints, pos];
        final updated = current.copyWith(points: _currentPoints);
        delegate.onCurrentAnnotationChanged(updated);
      }
    }
  }

  @override
  void onPanEnd(DragEndDetails details) {
    final current = delegate.currentAnnotation;
    if (current != null && current.points.length >= 2) {
      delegate.onAnnotationAdded(current);
      delegate.onSelectedAnnotationIdChanged(current.id);
    }
    delegate.onCurrentAnnotationChanged(null);
    _currentPoints = [];
  }

  @override
  void onTapUp(TapUpDetails details, Offset pos) {}
}
