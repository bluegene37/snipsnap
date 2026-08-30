import 'package:flutter/material.dart';
import '../models/annotation.dart';
import '../utils/constants.dart';
import 'arrow_tool.dart';
import 'blur_tool.dart';
import 'color_picker_tool.dart';
import 'crop_tool.dart';
import 'fill_tool.dart';
import 'highlighter_tool.dart';
import 'line_tool.dart';
import 'ocr_tool.dart';
import 'pen_tool.dart';
import 'ruler_tool.dart';
import 'select_tool.dart';
import 'shape_tool.dart';
import 'step_marker_tool.dart';
import 'text_tool.dart';

abstract interface class ToolDelegate {
  void onAnnotationAdded(Annotation annotation);
  void onActiveCropRectChanged(Rect? rect);
  void onCurrentAnnotationChanged(Annotation? annotation);
  void onSelectedAnnotationIdChanged(String? id);
  void onToolSelected(CanvasTool tool);
  void onStepCounterIncremented(int step);
  void showTextPrompt(Offset pos);

  /// Requests text extraction over [canvasRegion], in **canvas** coordinates.
  /// A null region means the whole capture.
  ///
  /// The implementor converts to native image pixels before the request leaves
  /// the canvas — handlers never see image space.
  void onExtractText(Rect? canvasRegion);

  List<Annotation> get annotations;
  String? get selectedAnnotationId;
  Annotation? get currentAnnotation;
  Rect? get activeCropRect;

  Color get activeColor;
  double get strokeWidth;
  double get opacity;
  double get fontSize;
  bool get isFilled;
  Color? get textBackgroundColor;
  Color? get fillColor;
  int get stepCounter;
  double get blurStrength;
  double get borderRadius;
  ShapeKind get shapeKind;
  LineStyle get lineStyle;
  BlurType get blurType;
  bool get isDoubleArrow;
  bool get hasShadow;
  double get fillTolerance;
  bool get isGlobalFill;
  bool get isShiftDown;
  bool get isAltDown;

  void updateAnnotation(String id, Annotation updatedAnnotation);
  void pushAnnotationsState(List<Annotation> newAnnotations);
  void onPerformCanvasFill(Offset pos);
  void onSampleColorFromCanvas(Offset pos);
  Annotation? hitTestAnnotation(Offset pos);
}

abstract class ToolHandler {
  final ToolDelegate delegate;

  ToolHandler(this.delegate);

  void onPanStart(DragStartDetails details, Offset pos);
  void onPanUpdate(DragUpdateDetails details, Offset pos);
  void onPanEnd(DragEndDetails details);
  void onTapUp(TapUpDetails details, Offset pos);

  /// A new annotation carrying **every** styling property the delegate exposes.
  ///
  /// Not merely a convenience: the moment a freshly drawn annotation is
  /// selected the parent adopts its style back into the tool defaults
  /// (`_updateActiveToolProperty(syncOnly: true, ...)` in `main_screen.dart`,
  /// which reads colour, background, fill colour, stroke, font size, opacity,
  /// fill, radius, shape kind, line style, blur type, blur strength, shadow and
  /// double-arrow). A handler that leaves one of those off its constructor call
  /// hands back a default, and the toolbar control silently resets after every
  /// stroke. Building them all in one place is what keeps that from drifting.
  @protected
  Annotation buildStyledAnnotation({
    required String id,
    required CanvasTool tool,
    Offset? startPoint,
    Offset? endPoint,
    List<Offset> points = const [],
  }) {
    return Annotation(
      id: id,
      tool: tool,
      color: delegate.activeColor,
      backgroundColor: delegate.textBackgroundColor,
      fillColor: delegate.fillColor,
      strokeWidth: delegate.strokeWidth,
      opacity: delegate.opacity,
      fontSize: delegate.fontSize,
      fill: delegate.isFilled,
      borderRadius: delegate.borderRadius,
      shapeKind: delegate.shapeKind,
      lineStyle: delegate.lineStyle,
      blurType: delegate.blurType,
      blurStrength: delegate.blurStrength,
      hasShadow: delegate.hasShadow,
      isDoubleArrow: delegate.isDoubleArrow,
      startPoint: startPoint,
      endPoint: endPoint,
      points: points,
    );
  }

  /// Whether a finished drag-to-draw gesture is big enough to keep.
  ///
  /// The rule is deliberately an `||`, mirroring the canvas's own
  /// `bounds.width < 3 && bounds.height < 3` discard: a dead-straight
  /// horizontal line or a zero-height redaction bar has one degenerate axis and
  /// still has to commit. Per-tool `width >= n && height >= n` variants swallow
  /// exactly those.
  @protected
  bool isCommittableDrag(Offset? start, Offset? end) {
    if (start == null || end == null) return false;
    final bounds = Rect.fromPoints(start, end);
    return bounds.width >= 3 || bounds.height >= 3;
  }
}

/// The handler that owns gestures for [tool].
///
/// `EditorCanvas` delegates to these rather than implementing gestures inline,
/// so tool behaviour lives in one place (GEMINI.md 1.1).
ToolHandler handlerFor(CanvasTool tool, ToolDelegate delegate) =>
    switch (tool) {
      CanvasTool.select => SelectToolHandler(delegate),
      CanvasTool.pen => PenToolHandler(delegate),
      CanvasTool.arrow => ArrowToolHandler(delegate),
      CanvasTool.line => LineToolHandler(delegate),
      CanvasTool.shape => ShapeToolHandler(delegate),
      CanvasTool.highlight => HighlighterToolHandler(delegate),
      CanvasTool.stepMarker => StepMarkerToolHandler(delegate),
      CanvasTool.text => TextToolHandler(delegate),
      CanvasTool.blur => BlurToolHandler(delegate),
      CanvasTool.ruler => RulerToolHandler(delegate),
      CanvasTool.crop => CropToolHandler(delegate),
      CanvasTool.fill => FillToolHandler(delegate),
      CanvasTool.colorPicker => ColorPickerToolHandler(delegate),
      CanvasTool.ocr => OcrToolHandler(delegate),
      // Not a pickable tool: `imagePatch` tags a dropped cut-and-move region,
      // and the Select tool owns every gesture that touches one.
      CanvasTool.imagePatch => SelectToolHandler(delegate),
    };
