import 'package:flutter/material.dart';
import 'tool_handler.dart';

class TextToolHandler extends ToolHandler {
  TextToolHandler(super.delegate);

  @override
  void onPanStart(DragStartDetails details, Offset pos) {
    delegate.showTextPrompt(pos);
  }

  @override
  void onPanUpdate(DragUpdateDetails details, Offset pos) {}

  @override
  void onPanEnd(DragEndDetails details) {}

  @override
  void onTapUp(TapUpDetails details, Offset pos) {
    delegate.showTextPrompt(pos);
  }
}
