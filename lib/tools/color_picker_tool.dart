import 'package:flutter/material.dart';
import 'tool_handler.dart';

class ColorPickerToolHandler extends ToolHandler {
  ColorPickerToolHandler(super.delegate);

  @override
  void onPanStart(DragStartDetails details, Offset pos) {}

  @override
  void onPanUpdate(DragUpdateDetails details, Offset pos) {}

  @override
  void onPanEnd(DragEndDetails details) {}

  @override
  void onTapUp(TapUpDetails details, Offset pos) {
    delegate.onSampleColorFromCanvas(pos);
  }
}
