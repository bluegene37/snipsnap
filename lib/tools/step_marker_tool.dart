import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../utils/constants.dart';
import 'tool_handler.dart';

class StepMarkerToolHandler extends ToolHandler {
  final Uuid _uuid = const Uuid();

  StepMarkerToolHandler(super.delegate);

  @override
  void onPanStart(DragStartDetails details, Offset pos) {
    _addMarker(pos);
  }

  @override
  void onPanUpdate(DragUpdateDetails details, Offset pos) {}

  @override
  void onPanEnd(DragEndDetails details) {}

  @override
  void onTapUp(TapUpDetails details, Offset pos) {
    _addMarker(pos);
  }

  void _addMarker(Offset pos) {
    final annotation = buildStyledAnnotation(
      id: _uuid.v4(),
      tool: CanvasTool.stepMarker,
      startPoint: pos,
    ).copyWith(stepNumber: delegate.stepCounter);
    delegate.onAnnotationAdded(annotation);
    delegate.onStepCounterIncremented(delegate.stepCounter + 1);
    delegate.onSelectedAnnotationIdChanged(annotation.id);
  }
}
