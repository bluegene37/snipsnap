import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:uuid/uuid.dart';
import '../models/annotation.dart';
import '../utils/constants.dart';

class EditorCanvas extends StatefulWidget {
  final String? imagePath;
  final List<Annotation> annotations;
  final CanvasTool activeTool;
  final ValueChanged<CanvasTool>? onToolSelected;
  final Color activeColor;
  final double strokeWidth;
  final double fontSize;
  final bool isFilled;
  final int stepCounter;
  final ValueChanged<Annotation> onAnnotationAdded;
  final ValueChanged<List<Annotation>>? onAnnotationsUpdated;
  final ValueChanged<List<Annotation>>? onAnnotationsLiveUpdated;
  final ValueChanged<int> onStepCounterIncremented;
  final ValueChanged<Annotation?>? onSelectAnnotation;
  final ValueChanged<Rect>? onApplyCrop;
  final ValueChanged<Color>? onSampleColor;
  final ValueChanged<Offset>? onPerformCanvasFill;
  final GlobalKey repaintBoundaryKey;
  final bool isDarkMode;
  final double opacity;
  final double rotation;
  final Color? textBackgroundColor;
  final double zoomScale;
  final ValueChanged<double>? onZoomScaleChanged;
  final int imageRevision;
  final double borderRadius;
  final LineStyle lineStyle;
  final BlurType blurType;
  final bool isDoubleArrow;

  const EditorCanvas({
    super.key,
    required this.imagePath,
    required this.annotations,
    required this.activeTool,
    this.onToolSelected,
    this.onSelectAnnotation,
    required this.activeColor,
    this.textBackgroundColor,
    required this.strokeWidth,
    required this.fontSize,
    required this.isFilled,
    required this.stepCounter,
    required this.onAnnotationAdded,
    this.onAnnotationsUpdated,
    this.onAnnotationsLiveUpdated,
    required this.onStepCounterIncremented,
    this.onApplyCrop,
    this.onSampleColor,
    this.onPerformCanvasFill,
    required this.repaintBoundaryKey,
    this.isDarkMode = false,
    this.opacity = 1.0,
    this.rotation = 0.0,
    this.zoomScale = 1.0,
    this.onZoomScaleChanged,
    this.imageRevision = 0,
    this.borderRadius = 8.0,
    this.lineStyle = LineStyle.solid,
    this.blurType = BlurType.gaussian,
    this.isDoubleArrow = false,
  });

  @override
  State<EditorCanvas> createState() => _EditorCanvasState();
}

enum _AnnHandle {
  none,
  body,
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
  rotate,
}

enum _CropHandle {
  none,
  move,
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
  top,
  bottom,
  left,
  right,
}

class _EditorCanvasState extends State<EditorCanvas> {
  final Uuid _uuid = const Uuid();
  bool _fileExists = false;
  late TransformationController _transformationController;

  // Selection, Dragging, Resizing, and Rotating State
  String? _selectedAnnotationId;
  String? _prevSelectedAnnotationId;
  bool _isDraggingAnnotation = false;
  bool _isResizingAnnotation = false;
  bool _isRotatingAnnotation = false;
  _AnnHandle _currentAnnHandle = _AnnHandle.none;

  // Crop State
  Rect? _activeCropRect;
  bool _isDraggingCrop = false;
  _CropHandle _currentCropHandle = _CropHandle.none;

  void _ensureCropRectInitialized() {
    if (widget.activeTool == CanvasTool.crop && _activeCropRect == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _activeCropRect == null) {
          final renderObj = widget.repaintBoundaryKey.currentContext?.findRenderObject();
          if (renderObj is RenderBox && renderObj.hasSize) {
            final size = renderObj.size;
            if (size.width > 0 && size.height > 0) {
              setState(() {
                _activeCropRect = Rect.fromLTWH(0, 0, size.width, size.height);
              });
            }
          }
        }
      });
    }
  }

  void _updateZoomMatrix(double targetScale) {
    final renderObj = widget.repaintBoundaryKey.currentContext?.findRenderObject();
    double vpW = 800.0;
    double vpH = 600.0;
    if (renderObj is RenderBox && renderObj.hasSize) {
      vpW = renderObj.size.width;
      vpH = renderObj.size.height;
    }

    final cx = vpW / 2;
    final cy = vpH / 2;

    final matrix = Matrix4.identity();
    if ((targetScale - 1.0).abs() > 0.001) {
      final storage = matrix.storage;
      storage[0] = targetScale;
      storage[5] = targetScale;
      storage[12] = (1.0 - targetScale) * cx;
      storage[13] = (1.0 - targetScale) * cy;
    }

    _transformationController.value = matrix;
  }

  @override
  void initState() {
    super.initState();
    _checkFileExists();
    _transformationController = TransformationController();
    if (widget.zoomScale != 1.0) {
      _updateZoomMatrix(widget.zoomScale);
    }
    _ensureCropRectInitialized();
  }

  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  bool _isInteractiveZooming = false;

  @override
  void didUpdateWidget(covariant EditorCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imagePath != widget.imagePath) {
      _checkFileExists();
    }

    if (oldWidget.zoomScale != widget.zoomScale && !_isInteractiveZooming) {
      _updateZoomMatrix(widget.zoomScale);
    }

    if (oldWidget.activeTool != widget.activeTool) {
      setState(() {
        _selectedAnnotationId = null;
        if (widget.activeTool != CanvasTool.crop) {
          _activeCropRect = null;
        }
      });
      widget.onSelectAnnotation?.call(null);

      if (widget.activeTool == CanvasTool.crop) {
        _ensureCropRectInitialized();
      }
    }

    final isSameSelection = _prevSelectedAnnotationId == _selectedAnnotationId;
    _prevSelectedAnnotationId = _selectedAnnotationId;

    // Live update selected annotation properties when controls change (ONLY if same item remains selected!)
    if (widget.activeTool == CanvasTool.select &&
        _selectedAnnotationId != null &&
        isSameSelection &&
        (oldWidget.activeColor != widget.activeColor ||
            oldWidget.strokeWidth != widget.strokeWidth ||
            oldWidget.opacity != widget.opacity ||
            oldWidget.fontSize != widget.fontSize ||
            oldWidget.isFilled != widget.isFilled ||
            oldWidget.rotation != widget.rotation ||
            oldWidget.textBackgroundColor != widget.textBackgroundColor ||
            oldWidget.borderRadius != widget.borderRadius ||
            oldWidget.lineStyle != widget.lineStyle ||
            oldWidget.blurType != widget.blurType ||
            oldWidget.isDoubleArrow != widget.isDoubleArrow)) {
      _updateSelectedAnnotationProperties();
    }
  }

  void _checkFileExists() {
    setState(() {
      _fileExists = widget.imagePath != null && File(widget.imagePath!).existsSync();
    });
  }

  void _updateSelectedAnnotationProperties() {
    if (_selectedAnnotationId == null) return;
    final callback = widget.onAnnotationsLiveUpdated ?? widget.onAnnotationsUpdated;
    if (callback == null) return;
    final index = widget.annotations.indexWhere((a) => a.id == _selectedAnnotationId);
    if (index != -1) {
      final oldAnn = widget.annotations[index];
      final updatedAnn = oldAnn.copyWith(
        color: widget.activeColor,
        backgroundColor: widget.textBackgroundColor,
        strokeWidth: widget.strokeWidth,
        opacity: widget.opacity,
        fontSize: widget.fontSize,
        fill: widget.isFilled,
        rotation: widget.rotation,
        borderRadius: widget.borderRadius,
        lineStyle: widget.lineStyle,
        blurType: widget.blurType,
        isDoubleArrow: widget.isDoubleArrow,
      );
      final newList = List<Annotation>.from(widget.annotations);
      newList[index] = updatedAnn;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          callback(newList);
        }
      });
    }
  }

  void _deleteSelectedAnnotation() {
    if (_selectedAnnotationId == null || widget.onAnnotationsUpdated == null) return;
    final updated = widget.annotations.where((a) => a.id != _selectedAnnotationId).toList();
    setState(() {
      _selectedAnnotationId = null;
    });
    widget.onAnnotationsUpdated!(updated);
  }

  // Current drawing shape state
  Annotation? _currentAnnotation;
  List<Offset> _currentPoints = [];

  _CropHandle _hitTestCropRect(Offset pos, Rect cropRect) {
    const handleRadius = 18.0;

    if ((pos - cropRect.topLeft).distance <= handleRadius) return _CropHandle.topLeft;
    if ((pos - cropRect.topRight).distance <= handleRadius) return _CropHandle.topRight;
    if ((pos - cropRect.bottomLeft).distance <= handleRadius) return _CropHandle.bottomLeft;
    if ((pos - cropRect.bottomRight).distance <= handleRadius) return _CropHandle.bottomRight;

    if ((pos.dy - cropRect.top).abs() <= handleRadius && pos.dx >= cropRect.left - handleRadius && pos.dx <= cropRect.right + handleRadius) {
      return _CropHandle.top;
    }
    if ((pos.dy - cropRect.bottom).abs() <= handleRadius && pos.dx >= cropRect.left - handleRadius && pos.dx <= cropRect.right + handleRadius) {
      return _CropHandle.bottom;
    }
    if ((pos.dx - cropRect.left).abs() <= handleRadius && pos.dy >= cropRect.top - handleRadius && pos.dy <= cropRect.bottom + handleRadius) {
      return _CropHandle.left;
    }
    if ((pos.dx - cropRect.right).abs() <= handleRadius && pos.dy >= cropRect.top - handleRadius && pos.dy <= cropRect.bottom + handleRadius) {
      return _CropHandle.right;
    }

    if (cropRect.contains(pos)) {
      return _CropHandle.move;
    }

    return _CropHandle.none;
  }

  void _updateCropRectWithDelta(Offset delta) {
    if (_activeCropRect == null) return;
    double left = _activeCropRect!.left;
    double top = _activeCropRect!.top;
    double right = _activeCropRect!.right;
    double bottom = _activeCropRect!.bottom;

    final renderObj = widget.repaintBoundaryKey.currentContext?.findRenderObject();
    double maxW = double.infinity;
    double maxH = double.infinity;
    if (renderObj is RenderBox && renderObj.hasSize) {
      maxW = renderObj.size.width;
      maxH = renderObj.size.height;
    }

    switch (_currentCropHandle) {
      case _CropHandle.move:
        double newLeft = left + delta.dx;
        double newTop = top + delta.dy;
        if (maxW.isFinite) {
          newLeft = newLeft.clamp(0.0, math.max(0.0, maxW - _activeCropRect!.width));
        }
        if (maxH.isFinite) {
          newTop = newTop.clamp(0.0, math.max(0.0, maxH - _activeCropRect!.height));
        }
        setState(() {
          _activeCropRect = Rect.fromLTWH(newLeft, newTop, _activeCropRect!.width, _activeCropRect!.height);
        });
        return;
      case _CropHandle.topLeft:
        left += delta.dx;
        top += delta.dy;
        break;
      case _CropHandle.topRight:
        right += delta.dx;
        top += delta.dy;
        break;
      case _CropHandle.bottomLeft:
        left += delta.dx;
        bottom += delta.dy;
        break;
      case _CropHandle.bottomRight:
        right += delta.dx;
        bottom += delta.dy;
        break;
      case _CropHandle.top:
        top += delta.dy;
        break;
      case _CropHandle.bottom:
        bottom += delta.dy;
        break;
      case _CropHandle.left:
        left += delta.dx;
        break;
      case _CropHandle.right:
        right += delta.dx;
        break;
      case _CropHandle.none:
        return;
    }

    // Clamp within 0..maxW and 0..maxH with min size 20px
    left = left.clamp(0.0, right - 20);
    top = top.clamp(0.0, bottom - 20);
    if (maxW.isFinite) right = right.clamp(left + 20, maxW);
    if (maxH.isFinite) bottom = bottom.clamp(top + 20, maxH);

    setState(() {
      _activeCropRect = Rect.fromLTRB(left, top, right, bottom);
    });
  }

  Annotation? _hitTestAnnotation(Offset pos) {
    for (int i = widget.annotations.length - 1; i >= 0; i--) {
      final ann = widget.annotations[i];
      if (_isPointInsideAnnotation(ann, pos)) {
        return ann;
      }
    }
    return null;
  }

  bool _isPointInsideAnnotation(Annotation ann, Offset point) {
    const hitPadding = 14.0;

    switch (ann.tool) {
      case CanvasTool.rectangle:
      case CanvasTool.oval:
      case CanvasTool.crop:
      case CanvasTool.blur:
        if (ann.startPoint == null || ann.endPoint == null) return false;
        final rect = Rect.fromPoints(ann.startPoint!, ann.endPoint!).inflate(hitPadding);
        return rect.contains(point);

      case CanvasTool.arrow:
      case CanvasTool.line:
        if (ann.startPoint == null || ann.endPoint == null) return false;
        return _distanceToSegment(point, ann.startPoint!, ann.endPoint!) <= (ann.strokeWidth / 2 + hitPadding);

      case CanvasTool.pen:
      case CanvasTool.highlight:
        if (ann.points.isEmpty) return false;
        final strokeRadius = ann.tool == CanvasTool.highlight ? ann.strokeWidth * 3 : ann.strokeWidth;
        for (int i = 0; i < ann.points.length - 1; i++) {
          if (_distanceToSegment(point, ann.points[i], ann.points[i + 1]) <= (strokeRadius / 2 + hitPadding)) {
            return true;
          }
        }
        return false;

      case CanvasTool.stepMarker:
        if (ann.startPoint == null) return false;
        return (point - ann.startPoint!).distance <= (16.0 + hitPadding);

      case CanvasTool.text:
        if (ann.startPoint == null || ann.text == null) return false;
        final textPainter = TextPainter(
          text: TextSpan(
            text: ann.text,
            style: TextStyle(fontSize: ann.fontSize, fontWeight: FontWeight.bold),
          ),
          textDirection: TextDirection.ltr,
        );
        textPainter.layout();
        final rect = Rect.fromLTWH(
          ann.startPoint!.dx - 6,
          ann.startPoint!.dy - 4,
          textPainter.width + 12,
          textPainter.height + 8,
        ).inflate(hitPadding);
        return rect.contains(point);

      default:
        if (ann.startPoint != null && ann.endPoint != null) {
          final rect = Rect.fromPoints(ann.startPoint!, ann.endPoint!).inflate(hitPadding);
          return rect.contains(point);
        }
        return false;
    }
  }

  double _distanceToSegment(Offset p, Offset v, Offset w) {
    final l2 = (v - w).distanceSquared;
    if (l2 == 0) return (p - v).distance;
    var t = ((p.dx - v.dx) * (w.dx - v.dx) + (p.dy - v.dy) * (w.dy - v.dy)) / l2;
    t = t.clamp(0.0, 1.0);
    final projection = Offset(v.dx + t * (w.dx - v.dx), v.dy + t * (w.dy - v.dy));
    return (p - projection).distance;
  }

  Annotation _translateAnnotation(Annotation ann, Offset delta) {
    return ann.copyWith(
      startPoint: ann.startPoint != null ? ann.startPoint! + delta : null,
      endPoint: ann.endPoint != null ? ann.endPoint! + delta : null,
      points: ann.points.map((p) => p + delta).toList(),
      rect: ann.rect?.shift(delta),
    );
  }

  _AnnHandle _hitTestAnnotationHandles(Offset pos, Annotation ann) {
    final rawBounds = _getAnnotationBoundingRect(ann);
    if (rawBounds == Rect.zero) return _AnnHandle.none;

    final bounds = rawBounds.inflate(8.0);
    const handleRadius = 18.0;

    // Rotation handle check (top stalk)
    final topCenter = bounds.topCenter;
    final rotPos = topCenter - const Offset(0, 22);
    if ((pos - rotPos).distance <= handleRadius) return _AnnHandle.rotate;

    if ((pos - bounds.topLeft).distance <= handleRadius) return _AnnHandle.topLeft;
    if ((pos - bounds.topRight).distance <= handleRadius) return _AnnHandle.topRight;
    if ((pos - bounds.bottomLeft).distance <= handleRadius) return _AnnHandle.bottomLeft;
    if ((pos - bounds.bottomRight).distance <= handleRadius) return _AnnHandle.bottomRight;

    if (_isPointInsideAnnotation(ann, pos)) {
      return _AnnHandle.body;
    }

    return _AnnHandle.none;
  }

  Annotation _resizeAnnotation(Annotation ann, _AnnHandle handle, Offset delta) {
    if (ann.tool == CanvasTool.text) {
      final step = (handle == _AnnHandle.bottomRight || handle == _AnnHandle.topRight) ? delta.dx : -delta.dx;
      final newSize = (ann.fontSize + step * 0.4).clamp(10.0, 72.0);
      return ann.copyWith(fontSize: newSize);
    }

    if (ann.startPoint == null || ann.endPoint == null) {
      return ann;
    }

    double startX = ann.startPoint!.dx;
    double startY = ann.startPoint!.dy;
    double endX = ann.endPoint!.dx;
    double endY = ann.endPoint!.dy;

    switch (handle) {
      case _AnnHandle.topLeft:
        startX += delta.dx;
        startY += delta.dy;
        break;
      case _AnnHandle.topRight:
        endX += delta.dx;
        startY += delta.dy;
        break;
      case _AnnHandle.bottomLeft:
        startX += delta.dx;
        endY += delta.dy;
        break;
      case _AnnHandle.bottomRight:
        endX += delta.dx;
        endY += delta.dy;
        break;
      case _AnnHandle.none:
      case _AnnHandle.body:
      case _AnnHandle.rotate:
        return ann;
    }

    if ((ann.tool == CanvasTool.pen || ann.tool == CanvasTool.highlight) && ann.points.length > 1) {
      final oldBounds = _getAnnotationBoundingRect(ann);
      if (oldBounds.width > 0 && oldBounds.height > 0) {
        final newBounds = Rect.fromLTRB(
          math.min(startX, endX),
          math.min(startY, endY),
          math.max(startX, endX),
          math.max(startY, endY),
        );
        final scaleX = newBounds.width / oldBounds.width;
        final scaleY = newBounds.height / oldBounds.height;
        final scaledPoints = ann.points.map((p) {
          final relX = (p.dx - oldBounds.left) * scaleX;
          final relY = (p.dy - oldBounds.top) * scaleY;
          return Offset(newBounds.left + relX, newBounds.top + relY);
        }).toList();
        return ann.copyWith(
          points: scaledPoints,
          startPoint: newBounds.topLeft,
          endPoint: newBounds.bottomRight,
        );
      }
    }

    return ann.copyWith(
      startPoint: Offset(startX, startY),
      endPoint: Offset(endX, endY),
    );
  }

  void _onPanStart(DragStartDetails details) {
    if (widget.imagePath == null) return;

    final pos = details.localPosition;

    // Check if in Crop Tool Mode
    if (widget.activeTool == CanvasTool.crop) {
      if (_activeCropRect != null) {
        final cropHandle = _hitTestCropRect(pos, _activeCropRect!);
        if (cropHandle != _CropHandle.none) {
          setState(() {
            _isDraggingCrop = true;
            _currentCropHandle = cropHandle;
          });
          return;
        }
      }
      // Start drawing a brand new crop rectangle
      setState(() {
        _selectedAnnotationId = null;
        _currentAnnotation = Annotation(
          id: _uuid.v4(),
          tool: CanvasTool.crop,
          color: Colors.transparent,
          startPoint: pos,
          endPoint: pos,
        );
        _activeCropRect = Rect.fromPoints(pos, pos);
      });
      return;
    }

    // Check if active crop rect handles or body is being dragged (if crop rect left behind)
    if (_activeCropRect != null) {
      final cropHandle = _hitTestCropRect(pos, _activeCropRect!);
      if (cropHandle != _CropHandle.none) {
        setState(() {
          _isDraggingCrop = true;
          _currentCropHandle = cropHandle;
        });
        return;
      }
    }

    // If an annotation is currently selected, check if its corner handles or body are clicked
    if (_selectedAnnotationId != null) {
      final selectedAnn = widget.annotations.firstWhere(
        (a) => a.id == _selectedAnnotationId,
        orElse: () => Annotation(id: '', tool: CanvasTool.pen, color: Colors.transparent),
      );
      if (selectedAnn.id.isNotEmpty) {
        final annHandle = _hitTestAnnotationHandles(pos, selectedAnn);
        if (annHandle != _AnnHandle.none) {
          // Push undo state once at gesture start
          widget.onAnnotationsUpdated?.call(List.from(widget.annotations));
          if (annHandle == _AnnHandle.body) {
            setState(() {
              _isDraggingAnnotation = true;
            });
          } else if (annHandle == _AnnHandle.rotate) {
            setState(() {
              _isRotatingAnnotation = true;
            });
          } else {
            setState(() {
              _isResizingAnnotation = true;
              _currentAnnHandle = annHandle;
            });
          }
          return;
        }
      }
    }

    final hit = _hitTestAnnotation(pos);

    // If hit an existing annotation -> select item and sync properties
    if (hit != null) {
      // Push undo state once at start of drag gesture
      widget.onAnnotationsUpdated?.call(List.from(widget.annotations));
      setState(() {
        _selectedAnnotationId = hit.id;
        _isDraggingAnnotation = true;
      });
      widget.onSelectAnnotation?.call(hit);
      return;
    }

    // If in select tool and nothing hit -> deselect
    if (widget.activeTool == CanvasTool.select) {
      setState(() {
        _selectedAnnotationId = null;
      });
      widget.onSelectAnnotation?.call(null);
      return;
    }

    // Otherwise deselect item and start drawing new shape
    setState(() {
      _selectedAnnotationId = null;
      _isDraggingAnnotation = false;
      _isResizingAnnotation = false;
      _isRotatingAnnotation = false;
      _currentAnnHandle = _AnnHandle.none;
    });

    if (widget.activeTool == CanvasTool.stepMarker || widget.activeTool == CanvasTool.text) {
      return; // Handled exclusively in _onTapUp to avoid duplicate double-creations
    }

    if (widget.activeTool == CanvasTool.pen || widget.activeTool == CanvasTool.highlight) {
      _currentPoints = [pos];
      _currentAnnotation = Annotation(
        id: _uuid.v4(),
        tool: widget.activeTool,
        color: widget.activeColor,
        strokeWidth: widget.strokeWidth,
        opacity: widget.opacity,
        points: _currentPoints,
      );
    } else {
      _currentAnnotation = Annotation(
        id: _uuid.v4(),
        tool: widget.activeTool,
        color: widget.activeColor,
        strokeWidth: widget.strokeWidth,
        opacity: widget.opacity,
        startPoint: pos,
        endPoint: pos,
        fill: widget.isFilled,
      );
    }
    setState(() {});
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_isDraggingCrop && _activeCropRect != null) {
      _updateCropRectWithDelta(details.delta);
      return;
    }

    if (_isRotatingAnnotation && _selectedAnnotationId != null) {
      final index = widget.annotations.indexWhere((a) => a.id == _selectedAnnotationId);
      final liveCallback = widget.onAnnotationsLiveUpdated ?? widget.onAnnotationsUpdated;
      if (index != -1 && liveCallback != null) {
        final ann = widget.annotations[index];
        final bounds = _getAnnotationBoundingRect(ann);
        final center = bounds.center;
        final angle = math.atan2(details.localPosition.dy - center.dy, details.localPosition.dx - center.dx) + math.pi / 2;
        final updatedAnn = ann.copyWith(rotation: angle);
        final newList = List<Annotation>.from(widget.annotations);
        newList[index] = updatedAnn;
        liveCallback(newList);
      }
      return;
    }

    if (_isResizingAnnotation && _selectedAnnotationId != null) {
      final delta = details.delta;
      final index = widget.annotations.indexWhere((a) => a.id == _selectedAnnotationId);
      final liveCallback = widget.onAnnotationsLiveUpdated ?? widget.onAnnotationsUpdated;
      if (index != -1 && liveCallback != null) {
        final resizedAnn = _resizeAnnotation(widget.annotations[index], _currentAnnHandle, delta);
        final newList = List<Annotation>.from(widget.annotations);
        newList[index] = resizedAnn;
        liveCallback(newList);
      }
      return;
    }

    if (_isDraggingAnnotation && _selectedAnnotationId != null) {
      final delta = details.delta;
      final index = widget.annotations.indexWhere((a) => a.id == _selectedAnnotationId);
      final liveCallback = widget.onAnnotationsLiveUpdated ?? widget.onAnnotationsUpdated;
      if (index != -1 && liveCallback != null) {
        final updatedAnn = _translateAnnotation(widget.annotations[index], delta);
        final newList = List<Annotation>.from(widget.annotations);
        newList[index] = updatedAnn;
        liveCallback(newList);
      }
      return;
    }

    if (_currentAnnotation == null) return;

    final pos = details.localPosition;

    if (_currentAnnotation!.tool == CanvasTool.crop) {
      setState(() {
        _currentAnnotation = _currentAnnotation!.copyWith(endPoint: pos);
        _activeCropRect = Rect.fromPoints(_currentAnnotation!.startPoint!, pos);
      });
      return;
    }

    if (widget.activeTool == CanvasTool.pen || widget.activeTool == CanvasTool.highlight) {
      setState(() {
        _currentPoints.add(pos);
        _currentAnnotation = _currentAnnotation!.copyWith(points: _currentPoints);
      });
    } else {
      setState(() {
        _currentAnnotation = _currentAnnotation!.copyWith(endPoint: pos);
      });
    }
  }

  void _onPanEnd(DragEndDetails details) {
    if (_isDraggingCrop) {
      setState(() {
        _isDraggingCrop = false;
        _currentCropHandle = _CropHandle.none;
      });
      return;
    }

    if (_isRotatingAnnotation) {
      setState(() {
        _isRotatingAnnotation = false;
      });
      return;
    }

    if (_isResizingAnnotation) {
      setState(() {
        _isResizingAnnotation = false;
        _currentAnnHandle = _AnnHandle.none;
      });
      return;
    }

    if (_isDraggingAnnotation) {
      setState(() {
        _isDraggingAnnotation = false;
      });
      return;
    }

    if (_currentAnnotation != null) {
      if (_currentAnnotation!.tool == CanvasTool.crop) {
        final renderObj = widget.repaintBoundaryKey.currentContext?.findRenderObject();
        double maxW = 800;
        double maxH = 600;
        if (renderObj is RenderBox && renderObj.hasSize) {
          maxW = renderObj.size.width;
          maxH = renderObj.size.height;
        }

        if (_activeCropRect != null && _activeCropRect!.width >= 15 && _activeCropRect!.height >= 15) {
          setState(() {
            _currentAnnotation = null;
          });
        } else {
          // Reset to full image crop box if drawn rect was too small / single click
          setState(() {
            _activeCropRect = Rect.fromLTWH(0, 0, maxW, maxH);
            _currentAnnotation = null;
          });
        }
        return;
      }

      widget.onAnnotationAdded(_currentAnnotation!);
      setState(() {
        _currentAnnotation = null;
        _currentPoints = [];
      });
    }
  }

  void _onTapUp(TapUpDetails details) {
    if (widget.imagePath == null) return;

    if (widget.activeTool == CanvasTool.crop) {
      return; // Do NOT exit crop mode on blank canvas tap!
    }

    final pos = details.localPosition;
    final hit = _hitTestAnnotation(pos);

    if (widget.activeTool == CanvasTool.fill) {
      if (hit != null) {
        final updated = hit.copyWith(
          fill: true,
          color: widget.activeColor,
        );
        final list = List<Annotation>.from(widget.annotations);
        final idx = list.indexWhere((a) => a.id == hit.id);
        if (idx != -1) {
          list[idx] = updated;
          widget.onAnnotationsUpdated?.call(list);
          setState(() {
            _selectedAnnotationId = updated.id;
          });
        }
      } else {
        _performCanvasFloodFill(pos);
      }
      return;
    }

    if (widget.activeTool == CanvasTool.colorPicker) {
      _sampleColorAt(pos);
      return;
    }

    if (hit != null) {
      setState(() {
        _selectedAnnotationId = hit.id;
      });
      widget.onSelectAnnotation?.call(hit);
      return;
    }

    if (widget.activeTool == CanvasTool.stepMarker) {
      final annotation = Annotation(
        id: _uuid.v4(),
        tool: CanvasTool.stepMarker,
        color: widget.activeColor,
        opacity: widget.opacity,
        startPoint: pos,
        stepNumber: widget.stepCounter,
      );
      widget.onAnnotationAdded(annotation);
      widget.onStepCounterIncremented(widget.stepCounter + 1);
      setState(() {
        _selectedAnnotationId = annotation.id;
      });
      widget.onSelectAnnotation?.call(annotation);
    } else if (widget.activeTool == CanvasTool.text) {
      _promptForText(pos);
    } else if (widget.activeTool == CanvasTool.select) {
      // Clicked on blank canvas space in Select mode: Deselect item
      setState(() {
        _selectedAnnotationId = null;
      });
      widget.onSelectAnnotation?.call(null);
    }
  }

  void _promptForText(Offset pos) {
    final controller = TextEditingController();
    final dialogBg = widget.isDarkMode ? AppColors.darkSurface : AppColors.lightSurface;
    final textColor = widget.isDarkMode ? Colors.white : Colors.black87;
    final hintColor = widget.isDarkMode ? Colors.white38 : Colors.black38;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: dialogBg,
        title: Text('Add Text Annotation', style: TextStyle(color: textColor)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: textColor),
          decoration: InputDecoration(
            hintText: 'Enter label or comment...',
            hintStyle: TextStyle(color: hintColor),
            enabledBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: AppColors.accent),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: widget.isDarkMode ? Colors.white54 : Colors.black54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent),
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                final annotation = Annotation(
                  id: _uuid.v4(),
                  tool: CanvasTool.text,
                  color: widget.activeColor,
                  backgroundColor: widget.textBackgroundColor,
                  opacity: widget.opacity,
                  startPoint: pos,
                  text: controller.text.trim(),
                  fontSize: widget.fontSize,
                  fill: widget.isFilled,
                );
                widget.onAnnotationAdded(annotation);
                setState(() {
                  _selectedAnnotationId = annotation.id;
                });
                widget.onSelectAnnotation?.call(annotation);
              }
              Navigator.pop(ctx);
            },
            child: const Text('Add Text', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _sampleColorAt(Offset localPos) async {
    if (widget.imagePath == null || !File(widget.imagePath!).existsSync()) return;
    try {
      final fileBytes = await File(widget.imagePath!).readAsBytes();
      final decoded = img.decodeImage(fileBytes);
      if (decoded == null) return;

      final renderObj = widget.repaintBoundaryKey.currentContext?.findRenderObject();
      if (renderObj is! RenderBox || !renderObj.hasSize) return;

      final canvasSize = renderObj.size;
      final inputSize = Size(decoded.width.toDouble(), decoded.height.toDouble());
      final fittedSizes = applyBoxFit(BoxFit.contain, inputSize, canvasSize);
      final destSize = fittedSizes.destination;

      final offsetX = (canvasSize.width - destSize.width) / 2.0;
      final offsetY = (canvasSize.height - destSize.height) / 2.0;

      final relX = localPos.dx - offsetX;
      final relY = localPos.dy - offsetY;

      if (relX < 0 || relY < 0 || relX >= destSize.width || relY >= destSize.height) {
        return;
      }

      final scaleX = decoded.width / destSize.width;
      final scaleY = decoded.height / destSize.height;

      final pixelX = (relX * scaleX).round().clamp(0, decoded.width - 1);
      final pixelY = (relY * scaleY).round().clamp(0, decoded.height - 1);

      final pixel = decoded.getPixel(pixelX, pixelY);
      final color = Color.fromARGB(
        pixel.a.toInt(),
        pixel.r.toInt(),
        pixel.g.toInt(),
        pixel.b.toInt(),
      );

      widget.onSampleColor?.call(color);
      widget.onToolSelected?.call(CanvasTool.select);
    } catch (e) {
      debugPrint('Error sampling color: $e');
    }
  }

  Future<void> _performCanvasFloodFill(Offset localPos) async {
    if (widget.imagePath == null || !File(widget.imagePath!).existsSync()) return;
    try {
      final fileBytes = await File(widget.imagePath!).readAsBytes();
      final decoded = img.decodeImage(fileBytes);
      if (decoded == null) return;

      final renderObj = widget.repaintBoundaryKey.currentContext?.findRenderObject();
      if (renderObj is! RenderBox || !renderObj.hasSize) return;

      final canvasSize = renderObj.size;
      final inputSize = Size(decoded.width.toDouble(), decoded.height.toDouble());
      final fittedSizes = applyBoxFit(BoxFit.contain, inputSize, canvasSize);
      final destSize = fittedSizes.destination;

      final offsetX = (canvasSize.width - destSize.width) / 2.0;
      final offsetY = (canvasSize.height - destSize.height) / 2.0;

      final relX = localPos.dx - offsetX;
      final relY = localPos.dy - offsetY;

      if (relX < 0 || relY < 0 || relX >= destSize.width || relY >= destSize.height) {
        return;
      }

      final scaleX = decoded.width / destSize.width;
      final scaleY = decoded.height / destSize.height;

      final pixelX = (relX * scaleX).round().clamp(0, decoded.width - 1);
      final pixelY = (relY * scaleY).round().clamp(0, decoded.height - 1);

      final fillColor = widget.activeColor;
      final r = (fillColor.r * 255).round();
      final g = (fillColor.g * 255).round();
      final b = (fillColor.b * 255).round();
      final a = (fillColor.a * 255).round();
      img.fillFlood(
        decoded,
        x: pixelX,
        y: pixelY,
        color: img.ColorRgba8(r, g, b, a),
        threshold: 24,
      );

      final updatedBytes = Uint8List.fromList(img.encodePng(decoded));
      await File(widget.imagePath!).writeAsBytes(updatedBytes);

      widget.onPerformCanvasFill?.call(localPos);
    } catch (e) {
      debugPrint('Error performing flood fill: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.imagePath == null || !_fileExists) {
      final textColor = widget.isDarkMode ? Colors.white : Colors.black87;
      final subTextColor = widget.isDarkMode ? Colors.white54 : Colors.black54;
      final circleBg = widget.isDarkMode
          ? AppColors.darkSurface.withValues(alpha: 0.5)
          : AppColors.lightSurface;
      final borderColor = widget.isDarkMode ? Colors.white10 : Colors.black12;

      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: circleBg,
                shape: BoxShape.circle,
                border: Border.all(color: borderColor),
              ),
              child: const Icon(Icons.add_a_photo_rounded, size: 56, color: AppColors.accent),
            ),
            const SizedBox(height: 16),
            Text(
              'No Screenshot Selected',
              style: TextStyle(color: textColor, fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'Click "Snip" in the top bar to capture screen area, or open an existing image.',
              style: TextStyle(color: subTextColor, fontSize: 13),
            ),
          ],
        ),
      );
    }

    Rect? selectedBounds;
    if (_selectedAnnotationId != null) {
      final selectedAnn = widget.annotations.firstWhere(
        (a) => a.id == _selectedAnnotationId,
        orElse: () => Annotation(id: '', tool: CanvasTool.pen, color: Colors.transparent),
      );
      if (selectedAnn.id.isNotEmpty) {
        final b = _getAnnotationBoundingRect(selectedAnn);
        if (b != Rect.zero) {
          selectedBounds = b.inflate(8.0);
        }
      }
    }

    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.delete ||
              event.logicalKey == LogicalKeyboardKey.backspace) {
            if (_selectedAnnotationId != null) {
              _deleteSelectedAnnotation();
              return KeyEventResult.handled;
            }
          } else if (event.logicalKey == LogicalKeyboardKey.escape) {
            setState(() {
              _selectedAnnotationId = null;
              _activeCropRect = null;
            });
            widget.onToolSelected?.call(CanvasTool.select);
            return KeyEventResult.handled;
          }

          // Single-key tool shortcuts (Shottr / Figma / Photoshop standard)
          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.keyV || key == LogicalKeyboardKey.keyS) {
            widget.onToolSelected?.call(CanvasTool.select);
            return KeyEventResult.handled;
          } else if (key == LogicalKeyboardKey.keyA) {
            widget.onToolSelected?.call(CanvasTool.arrow);
            return KeyEventResult.handled;
          } else if (key == LogicalKeyboardKey.keyR) {
            widget.onToolSelected?.call(CanvasTool.rectangle);
            return KeyEventResult.handled;
          } else if (key == LogicalKeyboardKey.keyO) {
            widget.onToolSelected?.call(CanvasTool.oval);
            return KeyEventResult.handled;
          } else if (key == LogicalKeyboardKey.keyP) {
            widget.onToolSelected?.call(CanvasTool.pen);
            return KeyEventResult.handled;
          } else if (key == LogicalKeyboardKey.keyH) {
            widget.onToolSelected?.call(CanvasTool.highlight);
            return KeyEventResult.handled;
          } else if (key == LogicalKeyboardKey.keyT) {
            widget.onToolSelected?.call(CanvasTool.text);
            return KeyEventResult.handled;
          } else if (key == LogicalKeyboardKey.keyB) {
            widget.onToolSelected?.call(CanvasTool.blur);
            return KeyEventResult.handled;
          } else if (key == LogicalKeyboardKey.keyC) {
            widget.onToolSelected?.call(CanvasTool.crop);
            return KeyEventResult.handled;
          } else if (key == LogicalKeyboardKey.keyN || key == LogicalKeyboardKey.digit1) {
            widget.onToolSelected?.call(CanvasTool.stepMarker);
            return KeyEventResult.handled;
          } else if (key == LogicalKeyboardKey.keyM) {
            widget.onToolSelected?.call(CanvasTool.ruler);
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: ClipRect(
        child: Stack(
          children: [
            // 1. STEADY Full-Viewport Checkerboard Background (Never shrinks or leaves black gaps on zoom out!)
            Positioned.fill(
              child: CustomPaint(
                painter: _SteadyCheckerboardPainter(isDarkMode: widget.isDarkMode),
              ),
            ),

            // 2. Interactive Zoom & Editing Layer with 2-Finger Trackpad & Scroll Wheel Support
            SizedBox.expand(
              child: Listener(
              onPointerSignal: (pointerSignal) {
                if (pointerSignal is PointerScrollEvent) {
                  final dy = pointerSignal.scrollDelta.dy;
                  if (dy != 0) {
                    final currentScale = _transformationController.value.getMaxScaleOnAxis();
                    final zoomDelta = dy > 0 ? -0.05 : 0.05;
                    final newScale = (currentScale + zoomDelta).clamp(0.2, 4.0);
                    _updateZoomMatrix(newScale);
                    widget.onZoomScaleChanged?.call(newScale);
                  }
                }
              },
              child: InteractiveViewer(
                transformationController: _transformationController,
                maxScale: 4.0,
                minScale: 0.2,
                boundaryMargin: const EdgeInsets.all(double.infinity),
                panEnabled: false,
                clipBehavior: Clip.hardEdge,
                onInteractionStart: (details) {
                  _isInteractiveZooming = true;
                },
                onInteractionUpdate: (details) {
                  final scale = _transformationController.value.getMaxScaleOnAxis();
                  if ((scale - widget.zoomScale).abs() > 0.02) {
                    widget.onZoomScaleChanged?.call(scale);
                  }
                },
                onInteractionEnd: (details) {
                  _isInteractiveZooming = false;
                  final finalScale = _transformationController.value.getMaxScaleOnAxis();
                  widget.onZoomScaleChanged?.call(finalScale);
                },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 0),
                child: RepaintBoundary(
                  key: widget.repaintBoundaryKey,
                  child: Stack(
                    alignment: Alignment.center,
                    clipBehavior: Clip.none,
                    children: [
                      // Base Screenshot Image
                      Image.file(
                        File(widget.imagePath!),
                        key: ValueKey('${widget.imagePath!}_${widget.imageRevision}'),
                        fit: BoxFit.contain,
                      ),

                // Real-time BackdropFilter Blur Overlay for Blur Annotations
                ...[...widget.annotations, ?_currentAnnotation]
                    .where((a) => a.tool == CanvasTool.blur && a.startPoint != null && a.endPoint != null)
                    .map((ann) {
                  final rect = Rect.fromPoints(ann.startPoint!, ann.endPoint!);
                  if (rect.width < 2 || rect.height < 2) return const SizedBox.shrink();
                  return Positioned.fromRect(
                    rect: rect,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: BackdropFilter(
                        filter: ui.ImageFilter.blur(sigmaX: 12.0, sigmaY: 12.0),
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.15),
                            border: Border.all(
                              color: AppColors.accent.withValues(alpha: 0.5),
                              width: 1.2,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }),

                // Active Movable & Resizable Crop Overlay (wrapped in IgnorePointer so gestures pass through to GestureDetector)
                if (_activeCropRect != null && _activeCropRect!.width > 10 && _activeCropRect!.height > 10)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _CropOverlayPainter(cropRect: _activeCropRect!),
                      ),
                    ),
                  ),

                // Interactive Gesture Overlay + CustomPainter (Behavior opaque, on top so drag/pan events are never blocked!)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: _onPanStart,
                    onPanUpdate: _onPanUpdate,
                    onPanEnd: _onPanEnd,
                    onTapUp: _onTapUp,
                    child: CustomPaint(
                      painter: _AnnotationPainter(
                        annotations: widget.annotations,
                        currentAnnotation: _currentAnnotation,
                        selectedAnnotationId: _selectedAnnotationId,
                      ),
                    ),
                  ),
                ),

                // Floating Action Chip Bar for Crop Confirmation (Always positioned safely on screen)
                if (_activeCropRect != null && _activeCropRect!.width > 10 && _activeCropRect!.height > 10)
                  Builder(
                    builder: (ctx) {
                      final renderObj = widget.repaintBoundaryKey.currentContext?.findRenderObject();
                      final renderSize = (renderObj is RenderBox && renderObj.hasSize) ? renderObj.size : null;
                      final canvasH = renderSize?.height ?? 600.0;
                      final canvasW = renderSize?.width ?? 800.0;

                      double barTop = _activeCropRect!.bottom + 14;
                      if (barTop > canvasH - 50) {
                        barTop = math.max(12, _activeCropRect!.top - 48);
                        if (barTop < 12) {
                          barTop = math.max(12, _activeCropRect!.bottom - 48);
                        }
                      }
                      final barLeft = (_activeCropRect!.center.dx - 110).clamp(12.0, math.max(12.0, canvasW - 220)).toDouble();

                      return Positioned(
                        left: barLeft,
                        top: barTop,
                        child: Material(
                          color: widget.isDarkMode ? AppColors.darkSurface : AppColors.lightSurface,
                          elevation: 8,
                          borderRadius: BorderRadius.circular(20),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: AppColors.accent, width: 1.5),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppColors.accent,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                  ),
                                  icon: const Icon(Icons.check_rounded, size: 16),
                                  label: const Text('Apply Crop', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                  onPressed: () {
                                    if (widget.onApplyCrop != null) {
                                      widget.onApplyCrop!(_activeCropRect!);
                                    }
                                    setState(() => _activeCropRect = null);
                                    widget.onToolSelected?.call(CanvasTool.select);
                                  },
                                ),
                                const SizedBox(width: 8),
                                OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                  ),
                                  icon: const Icon(Icons.close_rounded, size: 16),
                                  label: const Text('Cancel', style: TextStyle(fontSize: 12)),
                                  onPressed: () {
                                    setState(() => _activeCropRect = null);
                                    widget.onToolSelected?.call(CanvasTool.select);
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),

                // Floating Delete Chip overlay on selected annotation
                if (selectedBounds != null)
                  Positioned(
                    left: math.max(0, selectedBounds.topRight.dx - 10),
                    top: math.max(0, selectedBounds.topRight.dy - 14),
                    child: Tooltip(
                      message: 'Delete selected annotation (Delete / Backspace)',
                      child: Material(
                        color: Colors.redAccent,
                        elevation: 4,
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: _deleteSelectedAnnotation,
                          child: const Padding(
                            padding: EdgeInsets.all(5),
                            child: Icon(Icons.close_rounded, size: 14, color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  ),
],
),
),
);
  }
}

class _SteadyCheckerboardPainter extends CustomPainter {
  final bool isDarkMode;

  _SteadyCheckerboardPainter({required this.isDarkMode});

  @override
  void paint(Canvas canvas, Size size) {
    const squareSize = 14.0;
    final color1 = isDarkMode ? const Color(0xFF1B1917) : const Color(0xFFE8E2D9);
    final color2 = isDarkMode ? const Color(0xFF262320) : const Color(0xFFF5EFE6);

    final paint1 = Paint()..color = color1;
    final paint2 = Paint()..color = color2;

    int row = 0;
    for (double y = 0; y < size.height; y += squareSize) {
      int col = 0;
      for (double x = 0; x < size.width; x += squareSize) {
        final rect = Rect.fromLTWH(
          x,
          y,
          math.min(squareSize, size.width - x),
          math.min(squareSize, size.height - y),
        );
        canvas.drawRect(rect, ((row + col) % 2 == 0) ? paint1 : paint2);
        col++;
      }
      row++;
    }
  }

  @override
  bool shouldRepaint(covariant _SteadyCheckerboardPainter oldDelegate) {
    return oldDelegate.isDarkMode != isDarkMode;
  }
}

class _CropOverlayPainter extends CustomPainter {
  final Rect cropRect;

  _CropOverlayPainter({required this.cropRect});

  @override
  void paint(Canvas canvas, Size size) {
    final maskPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.55)
      ..style = PaintingStyle.fill;

    final fullRect = Rect.fromLTWH(0, 0, size.width, size.height).expandToInclude(cropRect).inflate(100.0);
    final path = Path()
      ..addRect(fullRect)
      ..addRect(cropRect);
    path.fillType = PathFillType.evenOdd;
    canvas.drawPath(path, maskPaint);

    final borderPaint = Paint()
      ..color = AppColors.accent
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;
    canvas.drawRect(cropRect, borderPaint);

    const handleSize = 9.0;
    void drawSquareHandle(Offset center) {
      final handleRect = Rect.fromCenter(center: center, width: handleSize, height: handleSize);
      // Drop shadow
      canvas.drawRect(
        handleRect.shift(const Offset(0, 1)),
        Paint()..color = Colors.black38..style = PaintingStyle.fill,
      );
      // White square fill
      canvas.drawRect(handleRect, Paint()..color = Colors.white..style = PaintingStyle.fill);
      // Dark border outline
      canvas.drawRect(
        handleRect,
        Paint()..color = AppColors.accent..strokeWidth = 1.2..style = PaintingStyle.stroke,
      );
    }

    final corners = [
      cropRect.topLeft,
      cropRect.topRight,
      cropRect.bottomLeft,
      cropRect.bottomRight,
    ];

    for (final c in corners) {
      drawSquareHandle(c);
    }

    final midEdges = [
      Offset(cropRect.center.dx, cropRect.top),
      Offset(cropRect.center.dx, cropRect.bottom),
      Offset(cropRect.left, cropRect.center.dy),
      Offset(cropRect.right, cropRect.center.dy),
    ];
    for (final m in midEdges) {
      drawSquareHandle(m);
    }

    // Dimension Badge Pill
    final textSpan = TextSpan(
      text: '${cropRect.width.round()} × ${cropRect.height.round()} px',
      style: const TextStyle(
        color: Colors.white,
        fontSize: 11,
        fontWeight: FontWeight.bold,
      ),
    );
    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();

    final badgeCenter = Offset(cropRect.center.dx, cropRect.top - 16);
    final badgeRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: badgeCenter, width: textPainter.width + 12, height: textPainter.height + 6),
      const Radius.circular(10),
    );
    final badgePaint = Paint()..color = AppColors.accent..style = PaintingStyle.fill;
    canvas.drawRRect(badgeRect, badgePaint);
    textPainter.paint(canvas, badgeCenter - Offset(textPainter.width / 2, textPainter.height / 2));
  }

  @override
  bool shouldRepaint(covariant _CropOverlayPainter oldDelegate) {
    return oldDelegate.cropRect != cropRect;
  }
}

Rect _getAnnotationBoundingRect(Annotation ann) {
  switch (ann.tool) {
    case CanvasTool.rectangle:
    case CanvasTool.oval:
    case CanvasTool.crop:
    case CanvasTool.blur:
    case CanvasTool.line:
    case CanvasTool.arrow:
      if (ann.startPoint != null && ann.endPoint != null) {
        return Rect.fromPoints(ann.startPoint!, ann.endPoint!);
      }
      return Rect.zero;

    case CanvasTool.pen:
    case CanvasTool.highlight:
      if (ann.points.isEmpty) return Rect.zero;
      double minX = ann.points.first.dx;
      double maxX = ann.points.first.dx;
      double minY = ann.points.first.dy;
      double maxY = ann.points.first.dy;
      for (final p in ann.points) {
        if (p.dx < minX) minX = p.dx;
        if (p.dx > maxX) maxX = p.dx;
        if (p.dy < minY) minY = p.dy;
        if (p.dy > maxY) maxY = p.dy;
      }
      return Rect.fromLTRB(minX, minY, maxX, maxY);

    case CanvasTool.stepMarker:
      if (ann.startPoint != null) {
        final r = ann.fontSize > 0 ? ann.fontSize : 16.0;
        return Rect.fromCircle(center: ann.startPoint!, radius: r);
      }
      return Rect.zero;

    case CanvasTool.text:
      if (ann.startPoint != null && ann.text != null) {
        final textPainter = TextPainter(
          text: TextSpan(
            text: ann.text,
            style: TextStyle(fontSize: ann.fontSize, fontWeight: FontWeight.bold),
          ),
          textDirection: TextDirection.ltr,
        );
        textPainter.layout();
        return Rect.fromLTWH(
          ann.startPoint!.dx - 6,
          ann.startPoint!.dy - 4,
          textPainter.width + 12,
          textPainter.height + 8,
        );
      }
      return Rect.zero;

    default:
      if (ann.startPoint != null && ann.endPoint != null) {
        return Rect.fromPoints(ann.startPoint!, ann.endPoint!);
      }
      return Rect.zero;
  }
}

class _AnnotationPainter extends CustomPainter {
  final List<Annotation> annotations;
  final Annotation? currentAnnotation;
  final String? selectedAnnotationId;

  _AnnotationPainter({
    required this.annotations,
    this.currentAnnotation,
    this.selectedAnnotationId,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final allAnnotations = [...annotations, ?currentAnnotation];
    for (final ann in allAnnotations) {
      final effectiveAlpha = (ann.color.a * ann.opacity).clamp(0.0, 1.0);
      final paint = Paint()
        ..color = ann.color.withValues(alpha: effectiveAlpha)
        ..strokeWidth = ann.strokeWidth
        ..style = ann.fill ? PaintingStyle.fill : PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      final bounds = _getAnnotationBoundingRect(ann);
      final hasRotation = ann.rotation != 0.0;

      if (hasRotation && bounds != Rect.zero) {
        canvas.save();
        final center = bounds.center;
        canvas.translate(center.dx, center.dy);
        canvas.rotate(ann.rotation);
        canvas.translate(-center.dx, -center.dy);
      }

      switch (ann.tool) {
        case CanvasTool.pen:
          if (ann.points.length > 1) {
            for (int i = 0; i < ann.points.length - 1; i++) {
              canvas.drawLine(ann.points[i], ann.points[i + 1], paint);
            }
          }
          break;

        case CanvasTool.highlight:
          final hlAlpha = (0.4 * ann.opacity).clamp(0.0, 1.0);
          final hlPaint = Paint()
            ..color = ann.color.withValues(alpha: hlAlpha)
            ..strokeWidth = ann.strokeWidth * 3
            ..strokeCap = StrokeCap.square
            ..style = PaintingStyle.stroke;
          if (ann.points.length > 1) {
            for (int i = 0; i < ann.points.length - 1; i++) {
              canvas.drawLine(ann.points[i], ann.points[i + 1], hlPaint);
            }
          }
          break;

        case CanvasTool.arrow:
          if (ann.startPoint != null && ann.endPoint != null) {
            _drawArrow(canvas, ann, paint);
          }
          break;

        case CanvasTool.line:
          if (ann.startPoint != null && ann.endPoint != null) {
            if (ann.lineStyle == LineStyle.dashed) {
              _drawDashedLine(canvas, ann.startPoint!, ann.endPoint!, paint);
            } else {
              canvas.drawLine(ann.startPoint!, ann.endPoint!, paint);
            }
          }
          break;

        case CanvasTool.rectangle:
          if (ann.startPoint != null && ann.endPoint != null) {
            final rect = Rect.fromPoints(ann.startPoint!, ann.endPoint!);
            final rrect = RRect.fromRectAndRadius(rect, Radius.circular(ann.borderRadius));
            canvas.drawRRect(rrect, paint);
          }
          break;

        case CanvasTool.oval:
          if (ann.startPoint != null && ann.endPoint != null) {
            final rect = Rect.fromPoints(ann.startPoint!, ann.endPoint!);
            canvas.drawOval(rect, paint);
          }
          break;

        case CanvasTool.blur:
          if (ann.startPoint != null && ann.endPoint != null) {
            final rect = Rect.fromPoints(ann.startPoint!, ann.endPoint!);
            final blurBg = Paint()
              ..color = Colors.black.withValues(alpha: 0.8)
              ..style = PaintingStyle.fill;
            canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(4)), blurBg);

            const blockSize = 8.0;
            final blockPaint1 = Paint()..color = Colors.white12..style = PaintingStyle.fill;
            final blockPaint2 = Paint()..color = Colors.white24..style = PaintingStyle.fill;
            int row = 0;
            for (double y = rect.top; y < rect.bottom; y += blockSize) {
              int col = 0;
              for (double x = rect.left; x < rect.right; x += blockSize) {
                final cellRect = Rect.fromLTWH(
                  x,
                  y,
                  math.min(blockSize, rect.right - x),
                  math.min(blockSize, rect.bottom - y),
                );
                canvas.drawRect(cellRect, ((row + col) % 2 == 0) ? blockPaint1 : blockPaint2);
                col++;
              }
              row++;
            }

            final borderPaint = Paint()
              ..color = AppColors.accent.withValues(alpha: 0.5)
              ..strokeWidth = 1.2
              ..style = PaintingStyle.stroke;
            canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(4)), borderPaint);
          }
          break;

        case CanvasTool.stepMarker:
          if (ann.startPoint != null && ann.stepNumber != null) {
            _drawStepMarker(canvas, ann.startPoint!, ann.stepNumber!, ann.color, ann.fontSize);
          }
          break;

        case CanvasTool.text:
          if (ann.startPoint != null && ann.text != null) {
            _drawText(canvas, ann.startPoint!, ann.text!, ann.color, ann.fontSize, ann.fill, ann.backgroundColor);
          }
          break;

        default:
          break;
      }

      if (hasRotation && bounds != Rect.zero) {
        canvas.restore();
      }
    }

    // Render selection box around selected annotation
    if (selectedAnnotationId != null) {
      final selectedAnn = annotations.firstWhere(
        (a) => a.id == selectedAnnotationId,
        orElse: () => Annotation(id: '', tool: CanvasTool.pen, color: Colors.transparent),
      );
      if (selectedAnn.id.isNotEmpty) {
        _drawSelectionFrame(canvas, selectedAnn);
      }
    }
  }

  void _drawSelectionFrame(Canvas canvas, Annotation ann) {
    final rawBounds = _getAnnotationBoundingRect(ann);
    if (rawBounds == Rect.zero) return;

    final bounds = rawBounds.inflate(8.0);
    final hasRotation = ann.rotation != 0.0;

    if (hasRotation) {
      canvas.save();
      final center = bounds.center;
      canvas.translate(center.dx, center.dy);
      canvas.rotate(ann.rotation);
      canvas.translate(-center.dx, -center.dy);
    }

    final selPaint = Paint()
      ..color = AppColors.accent
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    final rrect = RRect.fromRectAndRadius(bounds, const Radius.circular(6));
    canvas.drawRRect(rrect, selPaint);

    final corners = [
      bounds.topLeft,
      bounds.topRight,
      bounds.bottomLeft,
      bounds.bottomRight,
    ];

    final handleFill = Paint()..color = Colors.white..style = PaintingStyle.fill;
    final handleBorder = Paint()..color = AppColors.accent..strokeWidth = 2.0..style = PaintingStyle.stroke;

    for (final c in corners) {
      canvas.drawCircle(c, 4.5, handleFill);
      canvas.drawCircle(c, 4.5, handleBorder);
    }

    // Top Stalk Line + Rotation Handle Knob
    final topCenter = bounds.topCenter;
    final rotHandlePos = topCenter - const Offset(0, 22);

    canvas.drawLine(
      topCenter,
      rotHandlePos,
      Paint()..color = AppColors.accent..strokeWidth = 1.5,
    );

    canvas.drawCircle(rotHandlePos, 5.5, handleFill);
    canvas.drawCircle(rotHandlePos, 5.5, handleBorder);

    if (hasRotation) {
      canvas.restore();
    }
  }

  void _drawArrow(Canvas canvas, Annotation ann, Paint paint) {
    final start = ann.startPoint;
    final end = ann.endPoint;
    if (start == null || end == null) return;

    final strokeW = paint.strokeWidth;
    final angle = math.atan2(end.dy - start.dy, end.dx - start.dx);
    final arrowSize = math.max(16.0, strokeW * 3.2);

    final lineEndOffset = strokeW > 4.0 ? (strokeW * 0.5) : 0.0;
    final lineEnd = Offset(
      end.dx - lineEndOffset * math.cos(angle),
      end.dy - lineEndOffset * math.sin(angle),
    );

    if (ann.lineStyle == LineStyle.dashed) {
      _drawDashedLine(canvas, start, lineEnd, paint);
    } else {
      canvas.drawLine(start, lineEnd, paint);
    }

    final path = Path();
    path.moveTo(end.dx, end.dy);
    path.lineTo(
      end.dx - arrowSize * math.cos(angle - math.pi / 6),
      end.dy - arrowSize * math.sin(angle - math.pi / 6),
    );
    path.lineTo(
      end.dx - arrowSize * math.cos(angle + math.pi / 6),
      end.dy - arrowSize * math.sin(angle + math.pi / 6),
    );
    path.close();

    final headPaint = Paint()
      ..color = paint.color
      ..style = PaintingStyle.fill;

    canvas.drawPath(path, headPaint);

    if (ann.isDoubleArrow) {
      final startPath = Path();
      startPath.moveTo(start.dx, start.dy);
      startPath.lineTo(
        start.dx + arrowSize * math.cos(angle - math.pi / 6),
        start.dy + arrowSize * math.sin(angle - math.pi / 6),
      );
      startPath.lineTo(
        start.dx + arrowSize * math.cos(angle + math.pi / 6),
        start.dy + arrowSize * math.sin(angle + math.pi / 6),
      );
      startPath.close();
      canvas.drawPath(startPath, headPaint);
    }
  }

  void _drawDashedLine(Canvas canvas, Offset p1, Offset p2, Paint paint) {
    final distance = (p2 - p1).distance;
    if (distance == 0) return;

    final direction = (p2 - p1) / distance;
    const dashWidth = 8.0;
    const dashSpace = 6.0;

    double currentDistance = 0.0;
    while (currentDistance < distance) {
      final start = p1 + direction * currentDistance;
      final end = p1 + direction * math.min(currentDistance + dashWidth, distance);
      canvas.drawLine(start, end, paint);
      currentDistance += dashWidth + dashSpace;
    }
  }

  void _drawStepMarker(Canvas canvas, Offset center, int step, Color color, double fontSize) {
    final radius = fontSize > 0 ? fontSize : 16.0;

    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.3)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    canvas.drawCircle(center + const Offset(0, 2), radius, shadowPaint);

    final bodyPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius, bodyPaint);

    final borderPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.9)
      ..strokeWidth = math.max(1.5, radius * 0.1)
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(center, radius, borderPaint);

    final numFontSize = (radius * 0.9).clamp(9.0, 48.0);
    final textPainter = TextPainter(
      text: TextSpan(
        text: '$step',
        style: TextStyle(
          color: Colors.white,
          fontSize: numFontSize,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    textPainter.paint(
      canvas,
      center - Offset(textPainter.width / 2, textPainter.height / 2),
    );
  }

  void _drawText(Canvas canvas, Offset position, String text, Color color, double fontSize, bool fill, Color? backgroundColor) {
    final showBg = fill || (backgroundColor != null && backgroundColor != Colors.transparent);
    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
          shadows: showBg
              ? null
              : const [
                  Shadow(color: Colors.black87, offset: Offset(1, 1), blurRadius: 4),
                  Shadow(color: Colors.white70, offset: Offset(-0.5, -0.5), blurRadius: 2),
                ],
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();

    if (showBg) {
      final bgRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          position.dx - 6,
          position.dy - 4,
          textPainter.width + 12,
          textPainter.height + 8,
        ),
        const Radius.circular(6),
      );

      final bgColor = backgroundColor ?? Colors.black.withValues(alpha: 0.75);

      final bgPaint = Paint()
        ..color = bgColor
        ..style = PaintingStyle.fill;
      canvas.drawRRect(bgRect, bgPaint);

      final borderPaint = Paint()
        ..color = color.withValues(alpha: 0.6)
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke;
      canvas.drawRRect(bgRect, borderPaint);
    }

    textPainter.paint(canvas, position);
  }

  @override
  bool shouldRepaint(covariant _AnnotationPainter oldDelegate) {
    return oldDelegate.annotations != annotations ||
        oldDelegate.currentAnnotation != currentAnnotation ||
        oldDelegate.selectedAnnotationId != selectedAnnotationId;
  }
}
