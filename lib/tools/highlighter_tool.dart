import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../models/annotation.dart';
import '../utils/constants.dart';
import 'tool_handler.dart';

class HighlighterToolHandler extends ToolHandler {
  final _uuid = const Uuid();
  List<Offset> _currentPoints = [];
  Offset? _drawStart;

  HighlighterToolHandler(super.delegate);

  @override
  void onPanStart(DragStartDetails details, Offset pos) {
    _drawStart = pos;
    _currentPoints = [pos];
    final annotation = Annotation(
      id: _uuid.v4(),
      tool: CanvasTool.highlight,
      color: delegate.activeColor,
      strokeWidth: delegate.strokeWidth,
      opacity: delegate.opacity,
      points: _currentPoints,
    );
    delegate.onCurrentAnnotationChanged(annotation);
  }

  @override
  void onPanUpdate(DragUpdateDetails details, Offset pos) {
    final current = delegate.currentAnnotation;
    if (current != null && _drawStart != null) {
      if (delegate.isShiftDown) {
        // Shift-key straight highlight mode (locks to dominant horizontal or vertical axis)
        final start = _drawStart!;
        final dx = (pos.dx - start.dx).abs();
        final dy = (pos.dy - start.dy).abs();
        final constrainedPos = dx >= dy ? Offset(pos.dx, start.dy) : Offset(start.dx, pos.dy);
        _currentPoints = [start, constrainedPos];
        final updated = current.copyWith(points: _currentPoints);
        delegate.onCurrentAnnotationChanged(updated);
      } else {
        if (_currentPoints.isEmpty || (pos - _currentPoints.last).distance >= 1.5) {
          _currentPoints = [..._currentPoints, pos];
          final updated = current.copyWith(points: _currentPoints);
          delegate.onCurrentAnnotationChanged(updated);
        }
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
    _drawStart = null;
  }

  @override
  void onTapUp(TapUpDetails details, Offset pos) {}
}
