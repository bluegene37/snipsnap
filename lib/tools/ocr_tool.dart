import 'package:flutter/material.dart';

import 'tool_handler.dart';

/// Selects a region to extract text from. A drag extracts that region; a click
/// with no meaningful drag extracts the whole capture.
///
/// Like every other handler this works entirely in **canvas** coordinates. The
/// conversion to native image pixels happens once, in the canvas's
/// `onExtractText` implementation, because that is the only place holding a
/// projection.
class OcrToolHandler extends ToolHandler {
  /// Below this, a drag is indistinguishable from a click and is treated as one.
  ///
  /// Deliberately the same threshold as `OcrService.minRegionSide`, which
  /// rejects sub-8px crops outright: a drag smaller than that would come back
  /// empty anyway, and reporting "whole image" is more useful than reporting
  /// nothing.
  static const double minDragSide = 8.0;

  Offset? _start;
  Offset? _end;

  OcrToolHandler(super.delegate);

  @override
  void onPanStart(DragStartDetails details, Offset pos) {
    _start = pos;
    _end = pos;
  }

  @override
  void onPanUpdate(DragUpdateDetails details, Offset pos) {
    _end = pos;
  }

  @override
  void onPanEnd(DragEndDetails details) {
    final start = _start;
    final end = _end;
    _start = null;
    _end = null;
    if (start == null || end == null) return;

    final rect = Rect.fromPoints(start, end);
    delegate.onExtractText(
      rect.width < minDragSide || rect.height < minDragSide ? null : rect,
    );
  }

  @override
  void onTapUp(TapUpDetails details, Offset pos) {
    delegate.onExtractText(null);
  }
}
