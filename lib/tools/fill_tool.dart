import 'package:flutter/material.dart';
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
    if (hit != null) {
      final updated = hit.copyWith(
        fill: true,
        color: delegate.activeColor,
      );
      delegate.updateAnnotation(hit.id, updated);
    } else {
      delegate.onPerformCanvasFill(pos);
    }
  }
}
