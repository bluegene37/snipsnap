import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../models/annotation.dart';
import '../utils/constants.dart';
import 'tool_handler.dart';

class CropToolHandler extends ToolHandler {
  final Uuid _uuid = const Uuid();

  CropToolHandler(super.delegate);

  @override
  void onPanStart(DragStartDetails details, Offset pos) {
    if (delegate.activeCropRect == null) {
      delegate.onSelectedAnnotationIdChanged(null);
      delegate.onActiveCropRectChanged(Rect.fromPoints(pos, pos));
      
      final annotation = Annotation(
        id: _uuid.v4(),
        tool: CanvasTool.crop,
        color: Colors.transparent,
        startPoint: pos,
        endPoint: pos,
      );
      delegate.onCurrentAnnotationChanged(annotation);
    }
  }

  @override
  void onPanUpdate(DragUpdateDetails details, Offset pos) {
    if (delegate.currentAnnotation != null && delegate.currentAnnotation!.tool == CanvasTool.crop) {
      final updated = delegate.currentAnnotation!.copyWith(endPoint: pos);
      delegate.onCurrentAnnotationChanged(updated);
      delegate.onActiveCropRectChanged(Rect.fromPoints(updated.startPoint!, pos));
    }
  }

  @override
  void onPanEnd(DragEndDetails details) {
    if (delegate.currentAnnotation != null) {
      final rect = delegate.activeCropRect;
      if (rect != null && rect.width >= 15 && rect.height >= 15) {
        delegate.onCurrentAnnotationChanged(null);
      } else {
        // Too small to be a deliberate crop — drop the rect entirely so the
        // caller can fall back to its own default, rather than inventing an
        // 800x600 one here. That number was unrelated to the image on screen
        // and would jump the user's crop box to an arbitrary rectangle.
        delegate.onActiveCropRectChanged(null);
        delegate.onCurrentAnnotationChanged(null);
      }
    }
  }

  @override
  void onTapUp(TapUpDetails details, Offset pos) {
    // Crop doesn't exit on tap
  }
}
