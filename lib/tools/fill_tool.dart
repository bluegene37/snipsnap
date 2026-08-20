import 'package:flutter/material.dart';
import '../utils/constants.dart';
import 'tool_handler.dart';

class FillToolHandler extends ToolHandler {
  FillToolHandler(super.delegate);

  @override
  void onPanStart(DragStartDetails details, Offset pos) {}

  @override
  void onPanUpdate(DragUpdateDetails details, Offset pos) {}

  @override
  void onPanEnd(DragEndDetails details) {}

  @override
  void onTapUp(TapUpDetails details, Offset pos) {
    final hit = delegate.hitTestAnnotation(pos);
    // Only closed shapes take a bucket fill. Every other annotation type
    // (lines, arrows, pen strokes, blur boxes, text, markers) has no visible
    // fill of its own — recolouring it would look like the tool did nothing —
    // and hitTestAnnotation's bounding-box fallback means such annotations
    // can shadow large areas of the screenshot. Falling through to the bitmap
    // flood fill matches what the user is pointing at: the pixels.
    if (hit != null && hit.tool == CanvasTool.shape) {
      final updated = hit.copyWith(
        fill: true,
        fillColor: delegate.activeColor,
      );
      delegate.updateAnnotation(hit.id, updated);
      delegate.onSelectedAnnotationIdChanged(hit.id);
    } else {
      delegate.onPerformCanvasFill(pos);
    }
  }
}
