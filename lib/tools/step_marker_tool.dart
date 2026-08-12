import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../models/annotation.dart';
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
    final annotation = Annotation(
      id: _uuid.v4(),
      tool: CanvasTool.stepMarker,
      color: delegate.activeColor,
      opacity: delegate.opacity,
      startPoint: pos,
      stepNumber: delegate.stepCounter,
    );
    delegate.onAnnotationAdded(annotation);
    delegate.onStepCounterIncremented(delegate.stepCounter + 1);
    delegate.onToolSelected(CanvasTool.select);
    delegate.onSelectedAnnotationIdChanged(annotation.id);
  }
}
