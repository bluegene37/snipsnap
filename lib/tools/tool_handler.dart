import 'package:flutter/material.dart';
import '../models/annotation.dart';
import '../utils/constants.dart';

abstract class ToolDelegate {
  void onAnnotationAdded(Annotation annotation);
  void onActiveCropRectChanged(Rect? rect);
  void onCurrentAnnotationChanged(Annotation? annotation);
  void onSelectedAnnotationIdChanged(String? id);
  void onToolSelected(CanvasTool tool);
  void onStepCounterIncremented(int step);
  void showTextPrompt(Offset pos);

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
}
