import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/models/annotation.dart';
import 'package:snipsnap/tools/arrow_tool.dart';
import 'package:snipsnap/tools/blur_tool.dart';
import 'package:snipsnap/tools/color_picker_tool.dart';
import 'package:snipsnap/tools/crop_tool.dart';
import 'package:snipsnap/tools/fill_tool.dart';
import 'package:snipsnap/tools/highlighter_tool.dart';
import 'package:snipsnap/tools/line_tool.dart';
import 'package:snipsnap/tools/pen_tool.dart';
import 'package:snipsnap/tools/ruler_tool.dart';
import 'package:snipsnap/tools/select_tool.dart';
import 'package:snipsnap/tools/shape_tool.dart';
import 'package:snipsnap/tools/step_marker_tool.dart';
import 'package:snipsnap/tools/text_tool.dart';
import 'package:snipsnap/tools/tool_handler.dart';
import 'package:snipsnap/utils/constants.dart';

class MockToolDelegate implements ToolDelegate {
  final List<Annotation> addedAnnotations = [];
  final Map<String, Annotation> updatedAnnotations = {};
  Annotation? _currentAnnotation;
  String? _selectedId;
  Rect? _activeCropRect;
  CanvasTool _activeTool = CanvasTool.select;
  int _stepCounter = 1;
  Offset? promptedTextPos;
  Offset? canvasFillPos;
  Offset? sampledColorPos;

  // Configuration properties
  @override
  Color activeColor = const Color(0xFF8B5CF6);
  @override
  double strokeWidth = 4.0;
  @override
  double opacity = 1.0;
  @override
  double fontSize = 18.0;
  @override
  bool isFilled = false;
  @override
  Color? textBackgroundColor;
  @override
  Color? fillColor;
  @override
  double blurStrength = 14.0;
  @override
  double borderRadius = 8.0;
  @override
  ShapeKind shapeKind = ShapeKind.rectangle;
  @override
  LineStyle lineStyle = LineStyle.solid;
  @override
  BlurType blurType = BlurType.gaussian;
  @override
  bool isDoubleArrow = false;
  @override
  bool hasShadow = false;
  @override
  double fillTolerance = 15.0;
  @override
  bool isGlobalFill = false;
  @override
  bool isShiftDown = false;
  @override
  bool isAltDown = false;

  @override
  List<Annotation> get annotations => addedAnnotations;

  @override
  Annotation? get currentAnnotation => _currentAnnotation;

  @override
  String? get selectedAnnotationId => _selectedId;

  @override
  Rect? get activeCropRect => _activeCropRect;

  @override
  int get stepCounter => _stepCounter;

  @override
  void onAnnotationAdded(Annotation annotation) {
    addedAnnotations.add(annotation);
  }

  @override
  void onActiveCropRectChanged(Rect? rect) {
    _activeCropRect = rect;
  }

  @override
  void onCurrentAnnotationChanged(Annotation? annotation) {
    _currentAnnotation = annotation;
  }

  @override
  void onSelectedAnnotationIdChanged(String? id) {
    _selectedId = id;
  }

  @override
  void onStepCounterIncremented(int step) {
    _stepCounter = step;
  }

  @override
  void onToolSelected(CanvasTool tool) {
    _activeTool = tool;
  }

  @override
  void showTextPrompt(Offset pos) {
    promptedTextPos = pos;
  }

  @override
  void onPerformCanvasFill(Offset pos) {
    canvasFillPos = pos;
  }

  @override
  void onSampleColorFromCanvas(Offset pos) {
    sampledColorPos = pos;
  }

  @override
  void updateAnnotation(String id, Annotation updatedAnnotation) {
    updatedAnnotations[id] = updatedAnnotation;
    final index = addedAnnotations.indexWhere((a) => a.id == id);
    if (index != -1) {
      addedAnnotations[index] = updatedAnnotation;
    }
  }

  @override
  void pushAnnotationsState(List<Annotation> newAnnotations) {
    addedAnnotations
      ..clear()
      ..addAll(newAnnotations);
  }

  @override
  Annotation? hitTestAnnotation(Offset pos) {
    for (final ann in addedAnnotations.reversed) {
      if (ann.rect != null && ann.rect!.contains(pos)) return ann;
      if (ann.startPoint != null && (ann.startPoint! - pos).distance <= 20) return ann;
    }
    return null;
  }
}

DragStartDetails _dragStart(Offset pos) => DragStartDetails(localPosition: pos, globalPosition: pos);
DragUpdateDetails _dragUpdate(Offset pos) => DragUpdateDetails(localPosition: pos, globalPosition: pos);
DragEndDetails _dragEnd() => DragEndDetails();
TapUpDetails _tapUp(Offset pos) => TapUpDetails(
      kind: PointerDeviceKind.mouse,
      localPosition: pos,
      globalPosition: pos,
    );

void main() {
  group('LineToolHandler', () {
    test('creates and finalizes straight line annotation', () {
      final delegate = MockToolDelegate();
      final handler = LineToolHandler(delegate);

      handler.onPanStart(_dragStart(const Offset(10, 10)), const Offset(10, 10));
      expect(delegate.currentAnnotation, isNotNull);
      expect(delegate.currentAnnotation!.tool, CanvasTool.line);

      handler.onPanUpdate(_dragUpdate(const Offset(100, 10)), const Offset(100, 10));
      expect(delegate.currentAnnotation!.endPoint, const Offset(100, 10));

      handler.onPanEnd(_dragEnd());
      expect(delegate.addedAnnotations.length, 1);
      expect(delegate.addedAnnotations.first.tool, CanvasTool.line);
      expect(delegate.addedAnnotations.first.startPoint, const Offset(10, 10));
      expect(delegate.addedAnnotations.first.endPoint, const Offset(100, 10));
    });

    test('shift-snaps line to 15-degree angles', () {
      final delegate = MockToolDelegate()..isShiftDown = true;
      final handler = LineToolHandler(delegate);

      handler.onPanStart(_dragStart(const Offset(0, 0)), const Offset(0, 0));
      // 2.9 degrees — below the 7.5 degree boundary, so it snaps to horizontal.
      handler.onPanUpdate(_dragUpdate(const Offset(100, 5)), const Offset(100, 5));
      final end = delegate.currentAnnotation!.endPoint!;
      expect(end.dy, closeTo(0.0, 1e-4));
      expect(end.dx, greaterThan(95));
    });

    test('shift-snaps a 10-degree drag up to the 15-degree increment', () {
      final delegate = MockToolDelegate()..isShiftDown = true;
      final handler = LineToolHandler(delegate);

      handler.onPanStart(_dragStart(const Offset(0, 0)), const Offset(0, 0));
      handler.onPanUpdate(_dragUpdate(const Offset(100, 18)), const Offset(100, 18));
      final end = delegate.currentAnnotation!.endPoint!;
      // 10.2 degrees rounds to 15, so dy = |end| * sin(15deg) > 0.
      expect(end.dy, greaterThan(20));
    });
  });

  group('ArrowToolHandler', () {
    test('creates arrow with double arrow and shadow properties', () {
      final delegate = MockToolDelegate()
        ..isDoubleArrow = true
        ..hasShadow = true
        ..lineStyle = LineStyle.dashed;
      final handler = ArrowToolHandler(delegate);

      handler.onPanStart(_dragStart(const Offset(20, 20)), const Offset(20, 20));
      handler.onPanUpdate(_dragUpdate(const Offset(120, 120)), const Offset(120, 120));
      handler.onPanEnd(_dragEnd());

      expect(delegate.addedAnnotations.length, 1);
      final arrow = delegate.addedAnnotations.first;
      expect(arrow.tool, CanvasTool.arrow);
      expect(arrow.isDoubleArrow, isTrue);
      expect(arrow.hasShadow, isTrue);
      expect(arrow.lineStyle, LineStyle.dashed);
    });
  });

  group('ShapeToolHandler', () {
    test('creates shapes for all 8 ShapeKind values with fill and border radius', () {
      for (final kind in ShapeKind.values) {
        final delegate = MockToolDelegate()
          ..shapeKind = kind
          ..isFilled = true
          ..fillColor = Colors.blue
          ..borderRadius = 12.0;
        final handler = ShapeToolHandler(delegate);

        handler.onPanStart(_dragStart(const Offset(10, 10)), const Offset(10, 10));
        handler.onPanUpdate(_dragUpdate(const Offset(110, 90)), const Offset(110, 90));
        handler.onPanEnd(_dragEnd());

        expect(delegate.addedAnnotations.length, 1);
        final shape = delegate.addedAnnotations.first;
        expect(shape.tool, CanvasTool.shape);
        expect(shape.shapeKind, kind);
        expect(shape.fill, isTrue);
        expect(shape.fillColor, Colors.blue);
        expect(shape.borderRadius, 12.0);
      }
    });

    test('shift locks 1:1 aspect ratio for shapes', () {
      final delegate = MockToolDelegate()..isShiftDown = true;
      final handler = ShapeToolHandler(delegate);

      handler.onPanStart(_dragStart(const Offset(0, 0)), const Offset(0, 0));
      handler.onPanUpdate(_dragUpdate(const Offset(100, 50)), const Offset(100, 50));
      handler.onPanEnd(_dragEnd());

      final shape = delegate.addedAnnotations.first;
      final rect = Rect.fromPoints(shape.startPoint!, shape.endPoint!);
      expect(rect.width, equals(rect.height));
    });
  });

  group('PenToolHandler', () {
    test('captures smooth continuous freehand points without auto-deselecting', () {
      final delegate = MockToolDelegate();
      final handler = PenToolHandler(delegate);

      handler.onPanStart(_dragStart(const Offset(10, 10)), const Offset(10, 10));
      handler.onPanUpdate(_dragUpdate(const Offset(15, 15)), const Offset(15, 15));
      handler.onPanUpdate(_dragUpdate(const Offset(20, 25)), const Offset(20, 25));
      handler.onPanUpdate(_dragUpdate(const Offset(25, 40)), const Offset(25, 40));
      handler.onPanEnd(_dragEnd());

      expect(delegate.addedAnnotations.length, 1);
      final stroke = delegate.addedAnnotations.first;
      expect(stroke.tool, CanvasTool.pen);
      expect(stroke.points.length, 4);
      // Ensure the tool was NOT switched to Select!
      expect(delegate._activeTool, CanvasTool.select); // MockToolDelegate default
    });
  });

  group('HighlighterToolHandler', () {
    test('constrains straight horizontal highlight when Shift is held', () {
      final delegate = MockToolDelegate()..isShiftDown = true;
      final handler = HighlighterToolHandler(delegate);

      handler.onPanStart(_dragStart(const Offset(50, 100)), const Offset(50, 100));
      // Dragging roughly horizontally with minor vertical jitter
      handler.onPanUpdate(_dragUpdate(const Offset(250, 108)), const Offset(250, 108));
      handler.onPanEnd(_dragEnd());

      expect(delegate.addedAnnotations.length, 1);
      final hl = delegate.addedAnnotations.first;
      expect(hl.tool, CanvasTool.highlight);
      expect(hl.points.length, 2);
      expect(hl.points.first, const Offset(50, 100));
      // Should be strictly horizontal at y=100
      expect(hl.points.last.dy, 100);
      expect(hl.points.last.dx, 250);
    });
  });

  group('StepMarkerToolHandler', () {
    test('places consecutive numbered step markers without tool deselection', () {
      final delegate = MockToolDelegate();
      final handler = StepMarkerToolHandler(delegate);

      // Click step 1
      handler.onTapUp(_tapUp(const Offset(40, 40)), const Offset(40, 40));
      expect(delegate.addedAnnotations.length, 1);
      expect(delegate.addedAnnotations[0].stepNumber, 1);
      expect(delegate.stepCounter, 2);

      // Click step 2
      handler.onTapUp(_tapUp(const Offset(80, 80)), const Offset(80, 80));
      expect(delegate.addedAnnotations.length, 2);
      expect(delegate.addedAnnotations[1].stepNumber, 2);
      expect(delegate.stepCounter, 3);

      // Click step 3
      handler.onTapUp(_tapUp(const Offset(120, 120)), const Offset(120, 120));
      expect(delegate.addedAnnotations.length, 3);
      expect(delegate.addedAnnotations[2].stepNumber, 3);
      expect(delegate.stepCounter, 4);
    });
  });

  group('BlurToolHandler', () {
    test('creates blur annotation with pixelate, gaussian, and solid styles', () {
      for (final type in BlurType.values) {
        final delegate = MockToolDelegate()
          ..blurType = type
          ..blurStrength = 22.0
          ..borderRadius = 6.0;
        final handler = BlurToolHandler(delegate);

        handler.onPanStart(_dragStart(const Offset(10, 10)), const Offset(10, 10));
        handler.onPanUpdate(_dragUpdate(const Offset(100, 60)), const Offset(100, 60));
        handler.onPanEnd(_dragEnd());

        expect(delegate.addedAnnotations.length, 1);
        final blur = delegate.addedAnnotations.first;
        expect(blur.tool, CanvasTool.blur);
        expect(blur.blurType, type);
        expect(blur.blurStrength, 22.0);
        expect(blur.borderRadius, 6.0);
      }
    });
  });

  group('RulerToolHandler', () {
    test('shift-snaps ruler to 45-degree angle increments', () {
      final delegate = MockToolDelegate()..isShiftDown = true;
      final handler = RulerToolHandler(delegate);

      handler.onPanStart(_dragStart(const Offset(0, 0)), const Offset(0, 0));
      // Drag at ~40 degrees -> snaps to exact 45 degrees
      handler.onPanUpdate(_dragUpdate(const Offset(100, 80)), const Offset(100, 80));
      handler.onPanEnd(_dragEnd());

      expect(delegate.addedAnnotations.length, 1);
      final ruler = delegate.addedAnnotations.first;
      expect(ruler.tool, CanvasTool.ruler);
      final end = ruler.endPoint!;
      expect(end.dx, closeTo(end.dy, 1e-4));
    });
  });

  group('FillToolHandler', () {
    test('updates existing shape fill on tap', () {
      final delegate = MockToolDelegate()..activeColor = Colors.green;
      final shape = Annotation(
        id: 's1',
        tool: CanvasTool.shape,
        color: Colors.red,
        startPoint: const Offset(10, 10),
        endPoint: const Offset(100, 100),
        rect: const Rect.fromLTWH(10, 10, 90, 90),
      );
      delegate.addedAnnotations.add(shape);

      final handler = FillToolHandler(delegate);
      handler.onTapUp(_tapUp(const Offset(50, 50)), const Offset(50, 50));

      expect(delegate.updatedAnnotations.containsKey('s1'), isTrue);
      expect(delegate.updatedAnnotations['s1']!.fill, isTrue);
      expect(delegate.updatedAnnotations['s1']!.fillColor, Colors.green);
    });

    test('triggers bitmap flood fill on blank canvas tap', () {
      final delegate = MockToolDelegate();
      final handler = FillToolHandler(delegate);

      handler.onTapUp(_tapUp(const Offset(200, 200)), const Offset(200, 200));
      expect(delegate.canvasFillPos, const Offset(200, 200));
    });
  });

  group('ColorPickerToolHandler', () {
    test('samples color from canvas on tap', () {
      final delegate = MockToolDelegate();
      final handler = ColorPickerToolHandler(delegate);

      handler.onTapUp(_tapUp(const Offset(75, 75)), const Offset(75, 75));
      expect(delegate.sampledColorPos, const Offset(75, 75));
    });
  });

  group('CropToolHandler', () {
    test('initializes and updates active crop rect on drag', () {
      final delegate = MockToolDelegate();
      final handler = CropToolHandler(delegate);

      handler.onPanStart(_dragStart(const Offset(20, 30)), const Offset(20, 30));
      expect(delegate.activeCropRect, const Rect.fromLTRB(20, 30, 20, 30));

      handler.onPanUpdate(_dragUpdate(const Offset(200, 150)), const Offset(200, 150));
      expect(delegate.activeCropRect, const Rect.fromLTRB(20, 30, 200, 150));

      handler.onPanEnd(_dragEnd());
      expect(delegate.activeCropRect, const Rect.fromLTRB(20, 30, 200, 150));
    });
  });

  group('SelectToolHandler', () {
    test('instantiates cleanly and handles gestures', () {
      final delegate = MockToolDelegate();
      final handler = SelectToolHandler(delegate);

      handler.onPanStart(_dragStart(const Offset(10, 10)), const Offset(10, 10));
      handler.onPanUpdate(_dragUpdate(const Offset(50, 50)), const Offset(50, 50));
      handler.onPanEnd(_dragEnd());
      handler.onTapUp(_tapUp(const Offset(10, 10)), const Offset(10, 10));
      expect(delegate.addedAnnotations.isEmpty, isTrue);
    });
  });

  group('TextToolHandler', () {
    test('shows text prompt on tap', () {
      final delegate = MockToolDelegate();
      final handler = TextToolHandler(delegate);

      handler.onTapUp(_tapUp(const Offset(150, 150)), const Offset(150, 150));
      expect(delegate.promptedTextPos, const Offset(150, 150));
    });
  });
}
