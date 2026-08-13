import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:uuid/uuid.dart';

import '../models/annotation.dart';
import '../services/render_service.dart';
import '../utils/constants.dart';
import 'components/annotation_renderer.dart';

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

  /// Awaited before the flood fill overwrites the source file so the caller can
  /// snapshot the original bitmap for undo.
  final Future<void> Function()? onBeforeCanvasFill;
  final GlobalKey repaintBoundaryKey;
  final bool isDarkMode;
  final double opacity;
  final double rotation;
  final Color? textBackgroundColor;
  final Color? fillColor;
  final double zoomScale;
  final ValueChanged<double>? onZoomScaleChanged;
  final int imageRevision;
  final double borderRadius;
  final ShapeKind shapeKind;
  final LineStyle lineStyle;
  final BlurType blurType;
  final double blurStrength;
  final bool hasShadow;
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
    this.fillColor,
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
    this.onBeforeCanvasFill,
    required this.repaintBoundaryKey,
    this.isDarkMode = false,
    this.opacity = 1.0,
    this.rotation = 0.0,
    this.zoomScale = 1.0,
    this.onZoomScaleChanged,
    this.imageRevision = 0,
    this.borderRadius = 8.0,
    this.shapeKind = ShapeKind.rectangle,
    this.lineStyle = LineStyle.solid,
    this.blurType = BlurType.gaussian,
    this.blurStrength = 14.0,
    this.hasShadow = false,
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

/// Tools that place a shape by dragging out two corners / endpoints.
const _dragToDrawTools = {
  CanvasTool.shape,
  CanvasTool.arrow,
  CanvasTool.line,
  CanvasTool.blur,
  CanvasTool.ruler,
};

const _freehandTools = {CanvasTool.pen, CanvasTool.highlight};

class _EditorCanvasState extends State<EditorCanvas> {
  final Uuid _uuid = const Uuid();
  final FocusNode _focusNode = FocusNode(debugLabel: 'EditorCanvas');
  bool _fileExists = false;
  late TransformationController _transformationController;

  /// Decoded source pixels, used to render blur/pixelate regions on screen with
  /// exactly the same code path the exporter uses.
  ui.Image? _baseImage;
  int _baseImageToken = 0;

  // Selection / transform state
  String? _selectedAnnotationId;
  String? _prevSelectedAnnotationId;
  bool _isDraggingAnnotation = false;
  bool _isResizingAnnotation = false;
  bool _isRotatingAnnotation = false;
  _AnnHandle _currentAnnHandle = _AnnHandle.none;

  /// Geometry captured when a transform gesture begins so every frame is
  /// computed from the original shape instead of accumulating rounding drift.
  Annotation? _gestureOrigin;
  Offset _gestureStartPos = Offset.zero;

  // Crop state
  Rect? _activeCropRect;
  bool _isDraggingCrop = false;
  _CropHandle _currentCropHandle = _CropHandle.none;
  Rect? _cropOrigin;

  // Drawing state
  Annotation? _currentAnnotation;
  List<Offset> _currentPoints = [];
  Offset? _drawStart;

  MouseCursor _cursor = SystemMouseCursors.basic;
  bool _isInteractiveZooming = false;

  // Manual double-click detection (see _consumeDoubleTap).
  DateTime _lastTapAt = DateTime.fromMillisecondsSinceEpoch(0);
  Offset _lastTapPos = Offset.zero;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    _checkFileExists();
    _loadBaseImage();
    _transformationController = TransformationController();
    if (widget.zoomScale != 1.0) {
      _updateZoomMatrix(widget.zoomScale);
    }
    _ensureCropRectInitialized();
  }

  @override
  void dispose() {
    _baseImage?.dispose();
    _baseImage = null;
    _focusNode.dispose();
    _transformationController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant EditorCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.imagePath != widget.imagePath ||
        oldWidget.imageRevision != widget.imageRevision) {
      _checkFileExists();
      _loadBaseImage();
    }

    if (oldWidget.zoomScale != widget.zoomScale && !_isInteractiveZooming) {
      _updateZoomMatrix(widget.zoomScale);
    }

    if (oldWidget.activeTool != widget.activeTool) {
      _selectedAnnotationId = null;
      if (widget.activeTool != CanvasTool.crop) {
        _activeCropRect = null;
      }
      final callback = widget.onSelectAnnotation;
      if (callback != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) callback(null);
        });
      }
      if (widget.activeTool == CanvasTool.crop) {
        _ensureCropRectInitialized();
      }
    }

    // Property panel edits are applied to the selected annotation by the parent
    // (`_updateActiveToolProperty`); rotation is the only control the canvas
    // still owns, so it is the only one mirrored back here.
    final isSameSelection = _prevSelectedAnnotationId == _selectedAnnotationId;
    _prevSelectedAnnotationId = _selectedAnnotationId;
    if (widget.activeTool == CanvasTool.select &&
        _selectedAnnotationId != null &&
        isSameSelection &&
        oldWidget.rotation != widget.rotation) {
      _applyRotationToSelection(widget.rotation);
    }
  }

  Future<void> _loadBaseImage() async {
    final path = widget.imagePath;
    final token = ++_baseImageToken;

    if (path == null) {
      _baseImage?.dispose();
      if (mounted) setState(() => _baseImage = null);
      return;
    }

    final image = await RenderService.decodeImageFile(path);
    // A newer load (or disposal) won the race — drop this frame's native memory.
    if (!mounted || token != _baseImageToken) {
      image?.dispose();
      return;
    }
    setState(() {
      _baseImage?.dispose();
      _baseImage = image;
    });
  }

  void _checkFileExists() {
    final exists = widget.imagePath != null && File(widget.imagePath!).existsSync();
    if (exists != _fileExists) {
      setState(() => _fileExists = exists);
    }
  }

  void _updateZoomMatrix(double targetScale) {
    final size = _canvasSize;
    final cx = size.width / 2;
    final cy = size.height / 2;

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

  Size get _canvasSize {
    final renderObj = widget.repaintBoundaryKey.currentContext?.findRenderObject();
    if (renderObj is RenderBox && renderObj.hasSize) return renderObj.size;
    return const Size(800, 600);
  }

  /// Region the screenshot actually occupies inside the canvas viewport.
  Rect get _imageRect {
    final image = _baseImage;
    if (image == null) return Offset.zero & _canvasSize;
    return RenderService.imageRectInCanvas(
      imageSize: Size(image.width.toDouble(), image.height.toDouble()),
      canvasSize: _canvasSize,
    );
  }

  void _ensureCropRectInitialized() {
    if (widget.activeTool != CanvasTool.crop || _activeCropRect != null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _activeCropRect != null) return;
      // Default the crop box to the image itself rather than the whole
      // viewport, so the first drag never includes empty letterbox area.
      final rect = _imageRect;
      if (rect.width > 0 && rect.height > 0) {
        setState(() => _activeCropRect = rect);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Modifier keys
  // ---------------------------------------------------------------------------

  bool get _isShiftDown {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    return keys.contains(LogicalKeyboardKey.shiftLeft) ||
        keys.contains(LogicalKeyboardKey.shiftRight);
  }

  bool get _isAltDown {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    return keys.contains(LogicalKeyboardKey.altLeft) ||
        keys.contains(LogicalKeyboardKey.altRight);
  }

  bool get _isCommandDown {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    return keys.contains(LogicalKeyboardKey.metaLeft) ||
        keys.contains(LogicalKeyboardKey.metaRight) ||
        keys.contains(LogicalKeyboardKey.controlLeft) ||
        keys.contains(LogicalKeyboardKey.controlRight);
  }

  /// Shift-constrains a drag: square/circle for box tools, 15° increments for
  /// linear tools — the convention shared by Snagit, Shottr, Figma and Sketch.
  Offset _constrainEndPoint(Offset start, Offset end, CanvasTool tool) {
    if (!_isShiftDown) return end;

    if (tool == CanvasTool.shape || tool == CanvasTool.blur || tool == CanvasTool.crop) {
      final dx = end.dx - start.dx;
      final dy = end.dy - start.dy;
      final size = math.max(dx.abs(), dy.abs());
      return Offset(
        start.dx + (dx.isNegative ? -size : size),
        start.dy + (dy.isNegative ? -size : size),
      );
    }

    final delta = end - start;
    if (delta.distance == 0) return end;
    const stepRad = math.pi / 12; // 15°
    final snapped = (math.atan2(delta.dy, delta.dx) / stepRad).round() * stepRad;
    return start + Offset(math.cos(snapped), math.sin(snapped)) * delta.distance;
  }

  // ---------------------------------------------------------------------------
  // Selection helpers
  // ---------------------------------------------------------------------------

  Annotation? get _selectedAnnotation {
    if (_selectedAnnotationId == null) return null;
    for (final a in widget.annotations) {
      if (a.id == _selectedAnnotationId) return a;
    }
    return null;
  }

  /// Topmost annotation under [pos]. A precise pass runs first so a click
  /// inside a hollow shape reaches whatever sits under it; only if nothing is
  /// hit precisely does a bounding-box pass make large hollow shapes grabbable.
  Annotation? _hitTestAnnotation(Offset pos) {
    for (int i = widget.annotations.length - 1; i >= 0; i--) {
      if (AnnotationRenderer.hitTest(widget.annotations[i], pos)) {
        return widget.annotations[i];
      }
    }
    for (int i = widget.annotations.length - 1; i >= 0; i--) {
      if (AnnotationRenderer.hitTestBounds(widget.annotations[i], pos)) {
        return widget.annotations[i];
      }
    }
    return null;
  }

  _AnnHandle _hitTestAnnotationHandles(Offset pos, Annotation ann) {
    final bounds = AnnotationRenderer.selectionRect(ann);
    if (bounds == Rect.zero) return _AnnHandle.none;

    // Handles are drawn in the annotation's rotated frame, so the probe point
    // has to be rotated into that same frame before comparing distances.
    final local = AnnotationRenderer.toLocalSpace(ann, pos);
    const r = AnnotationRenderer.handleHitRadius;

    final rotPos = bounds.topCenter - const Offset(0, AnnotationRenderer.rotationHandleGap);
    if ((local - rotPos).distance <= r) return _AnnHandle.rotate;
    if ((local - bounds.topLeft).distance <= r) return _AnnHandle.topLeft;
    if ((local - bounds.topRight).distance <= r) return _AnnHandle.topRight;
    if ((local - bounds.bottomLeft).distance <= r) return _AnnHandle.bottomLeft;
    if ((local - bounds.bottomRight).distance <= r) return _AnnHandle.bottomRight;

    if (AnnotationRenderer.hitTest(ann, pos)) return _AnnHandle.body;
    return _AnnHandle.none;
  }

  void _replaceAnnotation(Annotation updated, {required bool live}) {
    final callback =
        live ? (widget.onAnnotationsLiveUpdated ?? widget.onAnnotationsUpdated) : widget.onAnnotationsUpdated;
    if (callback == null) return;
    final index = widget.annotations.indexWhere((a) => a.id == updated.id);
    if (index == -1) return;
    final list = List<Annotation>.from(widget.annotations);
    list[index] = updated;
    callback(list);
  }

  /// Records the pre-gesture state so the whole gesture collapses into a single
  /// undo step.
  void _pushHistoryCheckpoint() {
    widget.onAnnotationsUpdated?.call(List<Annotation>.from(widget.annotations));
  }

  void _applyRotationToSelection(double radians) {
    final ann = _selectedAnnotation;
    if (ann == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _replaceAnnotation(ann.copyWith(rotation: radians), live: true);
    });
  }

  void _deleteSelectedAnnotation() {
    if (_selectedAnnotationId == null || widget.onAnnotationsUpdated == null) return;
    final updated = widget.annotations.where((a) => a.id != _selectedAnnotationId).toList();
    setState(() => _selectedAnnotationId = null);
    widget.onSelectAnnotation?.call(null);
    widget.onAnnotationsUpdated!(updated);
  }

  void _duplicateSelectedAnnotation() {
    final ann = _selectedAnnotation;
    if (ann == null) return;
    const offset = Offset(16, 16);
    final clone = ann.translated(offset).copyWith(id: _uuid.v4());
    widget.onAnnotationAdded(clone);
    setState(() => _selectedAnnotationId = clone.id);
    widget.onSelectAnnotation?.call(clone);
  }

  void _nudgeSelectedAnnotation(Offset delta) {
    final ann = _selectedAnnotation;
    if (ann == null) return;
    _pushHistoryCheckpoint();
    _replaceAnnotation(ann.translated(delta), live: true);
  }

  // ---------------------------------------------------------------------------
  // Crop geometry
  // ---------------------------------------------------------------------------

  _CropHandle _hitTestCropRect(Offset pos, Rect cropRect) {
    const handleRadius = 18.0;

    if ((pos - cropRect.topLeft).distance <= handleRadius) return _CropHandle.topLeft;
    if ((pos - cropRect.topRight).distance <= handleRadius) return _CropHandle.topRight;
    if ((pos - cropRect.bottomLeft).distance <= handleRadius) return _CropHandle.bottomLeft;
    if ((pos - cropRect.bottomRight).distance <= handleRadius) return _CropHandle.bottomRight;

    final withinX = pos.dx >= cropRect.left - handleRadius && pos.dx <= cropRect.right + handleRadius;
    final withinY = pos.dy >= cropRect.top - handleRadius && pos.dy <= cropRect.bottom + handleRadius;

    if ((pos.dy - cropRect.top).abs() <= handleRadius && withinX) return _CropHandle.top;
    if ((pos.dy - cropRect.bottom).abs() <= handleRadius && withinX) return _CropHandle.bottom;
    if ((pos.dx - cropRect.left).abs() <= handleRadius && withinY) return _CropHandle.left;
    if ((pos.dx - cropRect.right).abs() <= handleRadius && withinY) return _CropHandle.right;

    if (cropRect.contains(pos)) return _CropHandle.move;
    return _CropHandle.none;
  }

  void _updateCropRect(Offset totalDelta) {
    final origin = _cropOrigin;
    if (origin == null) return;

    // The crop box is confined to the image, never the surrounding letterbox.
    final limit = _imageRect;
    double left = origin.left;
    double top = origin.top;
    double right = origin.right;
    double bottom = origin.bottom;

    switch (_currentCropHandle) {
      case _CropHandle.move:
        final newLeft = (origin.left + totalDelta.dx)
            .clamp(limit.left, math.max(limit.left, limit.right - origin.width))
            .toDouble();
        final newTop = (origin.top + totalDelta.dy)
            .clamp(limit.top, math.max(limit.top, limit.bottom - origin.height))
            .toDouble();
        setState(() {
          _activeCropRect = Rect.fromLTWH(newLeft, newTop, origin.width, origin.height);
        });
        return;
      case _CropHandle.topLeft:
        left += totalDelta.dx;
        top += totalDelta.dy;
        break;
      case _CropHandle.topRight:
        right += totalDelta.dx;
        top += totalDelta.dy;
        break;
      case _CropHandle.bottomLeft:
        left += totalDelta.dx;
        bottom += totalDelta.dy;
        break;
      case _CropHandle.bottomRight:
        right += totalDelta.dx;
        bottom += totalDelta.dy;
        break;
      case _CropHandle.top:
        top += totalDelta.dy;
        break;
      case _CropHandle.bottom:
        bottom += totalDelta.dy;
        break;
      case _CropHandle.left:
        left += totalDelta.dx;
        break;
      case _CropHandle.right:
        right += totalDelta.dx;
        break;
      case _CropHandle.none:
        return;
    }

    const minSize = 20.0;
    left = left.clamp(limit.left, math.max(limit.left, right - minSize));
    top = top.clamp(limit.top, math.max(limit.top, bottom - minSize));
    right = right.clamp(left + minSize, limit.right);
    bottom = bottom.clamp(top + minSize, limit.bottom);

    setState(() => _activeCropRect = Rect.fromLTRB(left, top, right, bottom));
  }

  // ---------------------------------------------------------------------------
  // Resize
  // ---------------------------------------------------------------------------

  Annotation _resizeAnnotation(Annotation origin, _AnnHandle handle, Offset totalDelta) {
    if (origin.tool == CanvasTool.text || origin.tool == CanvasTool.stepMarker) {
      // Point-anchored items scale by their type size rather than by bounds.
      final grow = (handle == _AnnHandle.bottomRight || handle == _AnnHandle.topRight)
          ? totalDelta.dx
          : -totalDelta.dx;
      return origin.copyWith(fontSize: (origin.fontSize + grow * 0.4).clamp(8.0, 120.0));
    }

    final bounds = AnnotationRenderer.boundingRect(origin);
    if (bounds == Rect.zero) return origin;

    double left = bounds.left;
    double top = bounds.top;
    double right = bounds.right;
    double bottom = bounds.bottom;

    switch (handle) {
      case _AnnHandle.topLeft:
        left += totalDelta.dx;
        top += totalDelta.dy;
        break;
      case _AnnHandle.topRight:
        right += totalDelta.dx;
        top += totalDelta.dy;
        break;
      case _AnnHandle.bottomLeft:
        left += totalDelta.dx;
        bottom += totalDelta.dy;
        break;
      case _AnnHandle.bottomRight:
        right += totalDelta.dx;
        bottom += totalDelta.dy;
        break;
      default:
        return origin;
    }

    if (_isShiftDown && bounds.width > 0 && bounds.height > 0) {
      // Preserve the original aspect ratio, anchored at the opposite corner.
      final ratio = bounds.height / bounds.width;
      final anchorLeft = handle == _AnnHandle.topRight || handle == _AnnHandle.bottomRight;
      final anchorTop = handle == _AnnHandle.bottomLeft || handle == _AnnHandle.bottomRight;
      final width = (right - left).abs();
      final height = width * ratio;
      if (anchorLeft) {
        right = left + width;
      } else {
        left = right - width;
      }
      if (anchorTop) {
        bottom = top + height;
      } else {
        top = bottom - height;
      }
    }

    final newBounds = Rect.fromLTRB(
      math.min(left, right),
      math.min(top, bottom),
      math.max(left, right),
      math.max(top, bottom),
    );

    if (_freehandTools.contains(origin.tool) && origin.points.length > 1) {
      if (bounds.width <= 0 || bounds.height <= 0) return origin;
      final scaleX = newBounds.width / bounds.width;
      final scaleY = newBounds.height / bounds.height;
      return origin.copyWith(
        points: origin.points
            .map((p) => Offset(
                  newBounds.left + (p.dx - bounds.left) * scaleX,
                  newBounds.top + (p.dy - bounds.top) * scaleY,
                ))
            .toList(),
      );
    }

    // Preserve the drag direction of the original shape so arrows/lines keep
    // pointing the same way after a resize.
    final origStart = origin.startPoint;
    final origEnd = origin.endPoint;
    if (origStart == null || origEnd == null) return origin;

    Offset remap(Offset p) => Offset(
          bounds.width == 0
              ? newBounds.left
              : newBounds.left + (p.dx - bounds.left) / bounds.width * newBounds.width,
          bounds.height == 0
              ? newBounds.top
              : newBounds.top + (p.dy - bounds.top) / bounds.height * newBounds.height,
        );

    return origin.copyWith(startPoint: remap(origStart), endPoint: remap(origEnd));
  }

  // ---------------------------------------------------------------------------
  // Gestures
  // ---------------------------------------------------------------------------

  Annotation _buildAnnotationForTool(CanvasTool tool, Offset pos) {
    return Annotation(
      id: _uuid.v4(),
      tool: tool,
      color: widget.activeColor,
      backgroundColor: widget.textBackgroundColor,
      fillColor: widget.fillColor,
      strokeWidth: widget.strokeWidth,
      opacity: widget.opacity,
      fontSize: widget.fontSize,
      fill: widget.isFilled,
      borderRadius: widget.borderRadius,
      shapeKind: widget.shapeKind,
      lineStyle: widget.lineStyle,
      blurType: widget.blurType,
      blurStrength: widget.blurStrength,
      hasShadow: widget.hasShadow,
      isDoubleArrow: widget.isDoubleArrow,
      startPoint: pos,
      endPoint: _freehandTools.contains(tool) ? null : pos,
      points: _freehandTools.contains(tool) ? [pos] : const [],
    );
  }

  void _onPanStart(DragStartDetails details) {
    if (widget.imagePath == null) return;
    _focusNode.requestFocus();
    final pos = details.localPosition;
    _gestureStartPos = pos;

    if (widget.activeTool == CanvasTool.crop) {
      if (_activeCropRect != null) {
        final handle = _hitTestCropRect(pos, _activeCropRect!);
        if (handle != _CropHandle.none) {
          setState(() {
            _isDraggingCrop = true;
            _currentCropHandle = handle;
            _cropOrigin = _activeCropRect;
          });
          return;
        }
      }
      setState(() {
        _selectedAnnotationId = null;
        _drawStart = pos;
        _activeCropRect = Rect.fromPoints(pos, pos);
      });
      return;
    }

    if (_activeCropRect != null) {
      final handle = _hitTestCropRect(pos, _activeCropRect!);
      if (handle != _CropHandle.none) {
        setState(() {
          _isDraggingCrop = true;
          _currentCropHandle = handle;
          _cropOrigin = _activeCropRect;
        });
        return;
      }
    }

    // Transform the current selection when its handles or body are grabbed.
    final selected = _selectedAnnotation;
    if (selected != null) {
      final handle = _hitTestAnnotationHandles(pos, selected);
      if (handle != _AnnHandle.none) {
        _pushHistoryCheckpoint();
        setState(() {
          _gestureOrigin = selected;
          _isDraggingAnnotation = handle == _AnnHandle.body;
          _isRotatingAnnotation = handle == _AnnHandle.rotate;
          _isResizingAnnotation = !_isDraggingAnnotation && !_isRotatingAnnotation;
          _currentAnnHandle = handle;
        });
        return;
      }
    }

    // Existing items can be grabbed directly with any tool active, matching the
    // "always live" selection behaviour of Snagit's editor.
    final hit = _hitTestAnnotation(pos);
    if (hit != null) {
      _pushHistoryCheckpoint();
      setState(() {
        _selectedAnnotationId = hit.id;
        _gestureOrigin = hit;
        _isDraggingAnnotation = true;
        _currentAnnHandle = _AnnHandle.body;
      });
      widget.onSelectAnnotation?.call(hit);
      return;
    }

    if (widget.activeTool == CanvasTool.select) {
      setState(() => _selectedAnnotationId = null);
      widget.onSelectAnnotation?.call(null);
      return;
    }

    setState(() {
      _selectedAnnotationId = null;
      _isDraggingAnnotation = false;
      _isResizingAnnotation = false;
      _isRotatingAnnotation = false;
      _currentAnnHandle = _AnnHandle.none;
      _gestureOrigin = null;
    });

    // Click-to-place tools are created on tap-up so a stray drag cannot spawn
    // duplicates.
    if (widget.activeTool == CanvasTool.stepMarker ||
        widget.activeTool == CanvasTool.text ||
        widget.activeTool == CanvasTool.fill ||
        widget.activeTool == CanvasTool.colorPicker) {
      return;
    }

    _drawStart = pos;
    _currentPoints = _freehandTools.contains(widget.activeTool) ? [pos] : [];
    setState(() {
      _currentAnnotation = _buildAnnotationForTool(widget.activeTool, pos);
    });
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final pos = details.localPosition;
    final totalDelta = pos - _gestureStartPos;

    if (_isDraggingCrop) {
      _updateCropRect(totalDelta);
      return;
    }

    final origin = _gestureOrigin;

    if (_isRotatingAnnotation && origin != null) {
      final center = AnnotationRenderer.boundingRect(origin).center;
      var angle = math.atan2(pos.dy - center.dy, pos.dx - center.dx) + math.pi / 2;
      if (_isShiftDown) {
        const step = math.pi / 12; // snap to 15°
        angle = (angle / step).round() * step;
      }
      _replaceAnnotation(origin.copyWith(rotation: angle), live: true);
      return;
    }

    if (_isResizingAnnotation && origin != null) {
      _replaceAnnotation(_resizeAnnotation(origin, _currentAnnHandle, totalDelta), live: true);
      return;
    }

    if (_isDraggingAnnotation && origin != null) {
      var delta = totalDelta;
      if (_isShiftDown) {
        // Lock movement to the dominant axis.
        delta = delta.dx.abs() > delta.dy.abs() ? Offset(delta.dx, 0) : Offset(0, delta.dy);
      }
      _replaceAnnotation(origin.translated(delta), live: true);
      return;
    }

    if (widget.activeTool == CanvasTool.crop && _drawStart != null) {
      final end = _constrainEndPoint(_drawStart!, pos, CanvasTool.crop);
      setState(() => _activeCropRect = Rect.fromPoints(_drawStart!, end).intersect(_imageRect));
      return;
    }

    if (_currentAnnotation == null || _drawStart == null) return;

    if (_freehandTools.contains(widget.activeTool)) {
      // Skip sub-pixel samples: fewer points means a smoother path and a much
      // smaller annotation to store and re-render.
      if (_currentPoints.isEmpty || (pos - _currentPoints.last).distance >= 1.5) {
        _currentPoints = [..._currentPoints, pos];
        setState(() => _currentAnnotation = _currentAnnotation!.copyWith(points: _currentPoints));
      }
      return;
    }

    var start = _drawStart!;
    var end = _constrainEndPoint(start, pos, widget.activeTool);

    if (_isAltDown && _dragToDrawTools.contains(widget.activeTool)) {
      // Alt/Option grows the shape outwards from the initial click point.
      final half = end - start;
      start = _drawStart! - half;
    }

    setState(() {
      _currentAnnotation = _currentAnnotation!.copyWith(startPoint: start, endPoint: end);
    });
  }

  void _onPanEnd(DragEndDetails details) {
    if (_isDraggingCrop) {
      setState(() {
        _isDraggingCrop = false;
        _currentCropHandle = _CropHandle.none;
        _cropOrigin = null;
      });
      return;
    }

    if (_isRotatingAnnotation || _isResizingAnnotation || _isDraggingAnnotation) {
      final settled = _selectedAnnotation;
      setState(() {
        _isRotatingAnnotation = false;
        _isResizingAnnotation = false;
        _isDraggingAnnotation = false;
        _currentAnnHandle = _AnnHandle.none;
        _gestureOrigin = null;
      });
      // Re-sync the property panel with the final geometry.
      if (settled != null) widget.onSelectAnnotation?.call(settled);
      return;
    }

    if (widget.activeTool == CanvasTool.crop) {
      final rect = _activeCropRect;
      if (rect == null || rect.width < 15 || rect.height < 15) {
        setState(() => _activeCropRect = _imageRect);
      }
      _drawStart = null;
      return;
    }

    final drawn = _currentAnnotation;
    setState(() {
      _currentAnnotation = null;
      _currentPoints = [];
      _drawStart = null;
    });

    if (drawn == null) return;

    // Discard accidental micro-drags instead of leaving invisible artefacts on
    // the canvas.
    if (_freehandTools.contains(drawn.tool)) {
      if (drawn.points.length < 2) return;
    } else {
      final bounds = AnnotationRenderer.boundingRect(drawn);
      if (bounds.width < 3 && bounds.height < 3) return;
    }

    widget.onAnnotationAdded(drawn);
    setState(() => _selectedAnnotationId = drawn.id);
    widget.onSelectAnnotation?.call(drawn);
  }

  /// Double clicks are detected by hand rather than with a
  /// `DoubleTapGestureRecognizer`, because adding that recognizer to the arena
  /// delays every single tap until the double-tap window expires — placing a
  /// step marker or text box would feel sluggish.
  bool _consumeDoubleTap(Offset pos) {
    final now = DateTime.now();
    final isDouble = now.difference(_lastTapAt) < const Duration(milliseconds: 350) &&
        (pos - _lastTapPos).distance < 12;
    _lastTapAt = isDouble ? DateTime.fromMillisecondsSinceEpoch(0) : now;
    _lastTapPos = pos;
    return isDouble;
  }

  void _onTapUp(TapUpDetails details) {
    if (widget.imagePath == null) return;
    _focusNode.requestFocus();
    if (widget.activeTool == CanvasTool.crop) return;

    final pos = details.localPosition;
    final hit = _hitTestAnnotation(pos);

    if (_consumeDoubleTap(pos)) {
      // Double-click a text callout to edit it in place.
      if (hit != null && hit.tool == CanvasTool.text) {
        setState(() => _selectedAnnotationId = hit.id);
        widget.onSelectAnnotation?.call(hit);
        _promptForText(hit.startPoint ?? pos, existing: hit);
        return;
      }
    }

    if (widget.activeTool == CanvasTool.fill) {
      if (hit != null) {
        _pushHistoryCheckpoint();
        _replaceAnnotation(
          hit.copyWith(fill: true, fillColor: widget.activeColor),
          live: true,
        );
        setState(() => _selectedAnnotationId = hit.id);
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
      setState(() => _selectedAnnotationId = hit.id);
      widget.onSelectAnnotation?.call(hit);
      return;
    }

    switch (widget.activeTool) {
      case CanvasTool.stepMarker:
        final annotation = _buildAnnotationForTool(CanvasTool.stepMarker, pos)
            .copyWith(stepNumber: widget.stepCounter, endPoint: null);
        widget.onAnnotationAdded(annotation);
        widget.onStepCounterIncremented(widget.stepCounter + 1);
        setState(() => _selectedAnnotationId = annotation.id);
        widget.onSelectAnnotation?.call(annotation);
        break;
      case CanvasTool.text:
        _promptForText(pos);
        break;
      case CanvasTool.select:
        setState(() => _selectedAnnotationId = null);
        widget.onSelectAnnotation?.call(null);
        break;
      default:
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // Text entry
  // ---------------------------------------------------------------------------

  void _promptForText(Offset pos, {Annotation? existing}) {
    final controller = TextEditingController(text: existing?.text ?? '');
    controller.selection = TextSelection(baseOffset: 0, extentOffset: controller.text.length);

    final dialogBg = widget.isDarkMode ? AppColors.darkSurface : AppColors.lightSurface;
    final textColor = widget.isDarkMode ? Colors.white : Colors.black87;
    final hintColor = widget.isDarkMode ? Colors.white38 : Colors.black38;

    void submit(BuildContext ctx) {
      final value = controller.text.trim();
      Navigator.pop(ctx);
      if (value.isEmpty) {
        // Clearing the text of an existing callout removes it.
        if (existing != null) {
          widget.onAnnotationsUpdated
              ?.call(widget.annotations.where((a) => a.id != existing.id).toList());
          setState(() => _selectedAnnotationId = null);
          widget.onSelectAnnotation?.call(null);
        }
        return;
      }

      if (existing != null) {
        _pushHistoryCheckpoint();
        _replaceAnnotation(existing.copyWith(text: value), live: true);
        return;
      }

      final annotation = _buildAnnotationForTool(CanvasTool.text, pos)
          .copyWith(text: value, endPoint: null);
      widget.onAnnotationAdded(annotation);
      setState(() => _selectedAnnotationId = annotation.id);
      widget.onSelectAnnotation?.call(annotation);
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: dialogBg,
        title: Text(
          existing != null ? 'Edit Text Annotation' : 'Add Text Annotation',
          style: TextStyle(color: textColor),
        ),
        content: SizedBox(
          width: 380,
          child: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 6,
            minLines: 1,
            textInputAction: TextInputAction.newline,
            style: TextStyle(color: textColor),
            decoration: InputDecoration(
              hintText: 'Enter label or comment...',
              hintStyle: TextStyle(color: hintColor),
              helperText: 'Shift+Enter for a new line',
              helperStyle: TextStyle(color: hintColor, fontSize: 11),
              enabledBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: AppColors.accent),
              ),
            ),
            onSubmitted: (_) => submit(ctx),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Cancel',
              style: TextStyle(color: widget.isDarkMode ? Colors.white54 : Colors.black54),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent),
            onPressed: () => submit(ctx),
            child: Text(
              existing != null ? 'Update' : 'Add Text',
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    ).then((_) => controller.dispose());
  }

  // ---------------------------------------------------------------------------
  // Pixel sampling tools
  // ---------------------------------------------------------------------------

  /// Converts a canvas point into a pixel coordinate of the source image, or
  /// null when the point lies outside the image (in the letterbox area).
  ({int x, int y})? _canvasPointToImagePixel(Offset localPos, int imgWidth, int imgHeight) {
    final rect = RenderService.imageRectInCanvas(
      imageSize: Size(imgWidth.toDouble(), imgHeight.toDouble()),
      canvasSize: _canvasSize,
    );
    if (rect.isEmpty || !rect.contains(localPos)) return null;

    final x = ((localPos.dx - rect.left) / rect.width * imgWidth).round().clamp(0, imgWidth - 1);
    final y = ((localPos.dy - rect.top) / rect.height * imgHeight).round().clamp(0, imgHeight - 1);
    return (x: x, y: y);
  }

  Future<void> _sampleColorAt(Offset localPos) async {
    final path = widget.imagePath;
    if (path == null || !File(path).existsSync()) return;
    try {
      final decoded = img.decodeImage(await File(path).readAsBytes());
      if (decoded == null) return;

      final pixelPos = _canvasPointToImagePixel(localPos, decoded.width, decoded.height);
      if (pixelPos == null) return;

      final pixel = decoded.getPixel(pixelPos.x, pixelPos.y);
      widget.onSampleColor?.call(Color.fromARGB(
        pixel.a.toInt(),
        pixel.r.toInt(),
        pixel.g.toInt(),
        pixel.b.toInt(),
      ));
      widget.onToolSelected?.call(CanvasTool.select);
    } catch (e) {
      debugPrint('Error sampling color: $e');
    }
  }

  Future<void> _performCanvasFloodFill(Offset localPos) async {
    final path = widget.imagePath;
    if (path == null || !File(path).existsSync()) return;
    try {
      final decoded = img.decodeImage(await File(path).readAsBytes());
      if (decoded == null) return;

      final pixelPos = _canvasPointToImagePixel(localPos, decoded.width, decoded.height);
      if (pixelPos == null) return;

      // Snapshot the pre-fill bitmap *before* it is overwritten, otherwise the
      // undo stack would capture the already-filled image.
      final beforeFill = widget.onBeforeCanvasFill;
      if (beforeFill != null) await beforeFill();

      final fill = widget.activeColor;
      img.fillFlood(
        decoded,
        x: pixelPos.x,
        y: pixelPos.y,
        color: img.ColorRgba8(
          (fill.r * 255).round(),
          (fill.g * 255).round(),
          (fill.b * 255).round(),
          (fill.a * 255).round(),
        ),
        threshold: 24,
      );

      await File(path).writeAsBytes(Uint8List.fromList(img.encodePng(decoded)));
      widget.onPerformCanvasFill?.call(localPos);
    } catch (e) {
      debugPrint('Error performing flood fill: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Keyboard
  // ---------------------------------------------------------------------------

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.delete || key == LogicalKeyboardKey.backspace) {
      if (_selectedAnnotationId != null) {
        _deleteSelectedAnnotation();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.escape) {
      setState(() {
        _selectedAnnotationId = null;
        _activeCropRect = null;
        _currentAnnotation = null;
        _drawStart = null;
      });
      widget.onSelectAnnotation?.call(null);
      widget.onToolSelected?.call(CanvasTool.select);
      return KeyEventResult.handled;
    }

    // Nudge the selection with the arrow keys; Shift jumps 10px at a time.
    final nudges = <LogicalKeyboardKey, Offset>{
      LogicalKeyboardKey.arrowLeft: Offset(-1, 0),
      LogicalKeyboardKey.arrowRight: Offset(1, 0),
      LogicalKeyboardKey.arrowUp: Offset(0, -1),
      LogicalKeyboardKey.arrowDown: Offset(0, 1),
    };
    final nudge = nudges[key];
    if (nudge != null) {
      if (_selectedAnnotationId == null) return KeyEventResult.ignored;
      _nudgeSelectedAnnotation(nudge * (_isShiftDown ? 10.0 : 1.0));
      return KeyEventResult.handled;
    }

    if (_isCommandDown) {
      if (key == LogicalKeyboardKey.keyD) {
        _duplicateSelectedAnnotation();
        return KeyEventResult.handled;
      }
      // Every other Cmd/Ctrl chord belongs to the app-level shortcut handler.
      return KeyEventResult.ignored;
    }

    if (event is KeyRepeatEvent) return KeyEventResult.ignored;

    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      if (widget.activeTool == CanvasTool.crop && _activeCropRect != null) {
        _applyCrop();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    final toolKeys = <LogicalKeyboardKey, CanvasTool>{
      LogicalKeyboardKey.keyV: CanvasTool.select,
      LogicalKeyboardKey.keyP: CanvasTool.pen,
      LogicalKeyboardKey.keyL: CanvasTool.line,
      LogicalKeyboardKey.keyA: CanvasTool.arrow,
      LogicalKeyboardKey.keyR: CanvasTool.shape,
      LogicalKeyboardKey.keyS: CanvasTool.shape,
      LogicalKeyboardKey.keyH: CanvasTool.highlight,
      LogicalKeyboardKey.keyT: CanvasTool.text,
      LogicalKeyboardKey.keyN: CanvasTool.stepMarker,
      LogicalKeyboardKey.digit1: CanvasTool.stepMarker,
      LogicalKeyboardKey.keyB: CanvasTool.blur,
      LogicalKeyboardKey.keyM: CanvasTool.ruler,
      LogicalKeyboardKey.keyG: CanvasTool.fill,
      LogicalKeyboardKey.keyI: CanvasTool.colorPicker,
      LogicalKeyboardKey.keyC: CanvasTool.crop,
    };
    final tool = toolKeys[key];
    if (tool != null) {
      widget.onToolSelected?.call(tool);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _applyCrop() {
    final rect = _activeCropRect;
    if (rect == null) return;
    widget.onApplyCrop?.call(rect);
    setState(() => _activeCropRect = null);
    widget.onToolSelected?.call(CanvasTool.select);
  }

  // ---------------------------------------------------------------------------
  // Cursor
  // ---------------------------------------------------------------------------

  MouseCursor _cursorForHandle(_AnnHandle handle) {
    switch (handle) {
      case _AnnHandle.topLeft:
      case _AnnHandle.bottomRight:
        return SystemMouseCursors.resizeUpLeftDownRight;
      case _AnnHandle.topRight:
      case _AnnHandle.bottomLeft:
        return SystemMouseCursors.resizeUpRightDownLeft;
      case _AnnHandle.rotate:
        return SystemMouseCursors.grab;
      case _AnnHandle.body:
        return SystemMouseCursors.move;
      case _AnnHandle.none:
        return SystemMouseCursors.basic;
    }
  }

  void _updateCursor(Offset pos) {
    MouseCursor next;

    final selected = _selectedAnnotation;
    final handle = selected != null ? _hitTestAnnotationHandles(pos, selected) : _AnnHandle.none;

    if (handle != _AnnHandle.none) {
      next = _cursorForHandle(handle);
    } else if (widget.activeTool == CanvasTool.crop) {
      final crop = _activeCropRect;
      final cropHandle = crop != null ? _hitTestCropRect(pos, crop) : _CropHandle.none;
      next = switch (cropHandle) {
        _CropHandle.move => SystemMouseCursors.move,
        _CropHandle.topLeft || _CropHandle.bottomRight => SystemMouseCursors.resizeUpLeftDownRight,
        _CropHandle.topRight || _CropHandle.bottomLeft => SystemMouseCursors.resizeUpRightDownLeft,
        _CropHandle.top || _CropHandle.bottom => SystemMouseCursors.resizeUpDown,
        _CropHandle.left || _CropHandle.right => SystemMouseCursors.resizeLeftRight,
        _CropHandle.none => SystemMouseCursors.precise,
      };
    } else if (widget.activeTool == CanvasTool.select) {
      next = _hitTestAnnotation(pos) != null ? SystemMouseCursors.move : SystemMouseCursors.basic;
    } else if (widget.activeTool == CanvasTool.colorPicker ||
        widget.activeTool == CanvasTool.fill) {
      next = SystemMouseCursors.precise;
    } else if (widget.activeTool == CanvasTool.text) {
      next = SystemMouseCursors.text;
    } else {
      next = SystemMouseCursors.precise;
    }

    if (next != _cursor) setState(() => _cursor = next);
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (widget.imagePath == null || !_fileExists) {
      return _buildEmptyState();
    }

    final selected = _selectedAnnotation;
    final selectedBounds =
        selected != null ? AnnotationRenderer.selectionRect(selected) : Rect.zero;

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: ClipRect(
        child: Stack(
          children: [
            Positioned.fill(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _SteadyCheckerboardPainter(isDarkMode: widget.isDarkMode),
                ),
              ),
            ),
            SizedBox.expand(
              child: Listener(
                onPointerSignal: (signal) {
                  if (signal is! PointerScrollEvent) return;
                  final dy = signal.scrollDelta.dy;
                  if (dy == 0) return;
                  final current = _transformationController.value.getMaxScaleOnAxis();
                  final newScale = (current + (dy > 0 ? -0.05 : 0.05)).clamp(0.2, 4.0);
                  _updateZoomMatrix(newScale);
                  widget.onZoomScaleChanged?.call(newScale);
                },
                child: InteractiveViewer(
                  transformationController: _transformationController,
                  maxScale: 4.0,
                  minScale: 0.2,
                  boundaryMargin: const EdgeInsets.all(double.infinity),
                  panEnabled: false,
                  clipBehavior: Clip.hardEdge,
                  onInteractionStart: (_) => _isInteractiveZooming = true,
                  onInteractionUpdate: (_) {
                    final scale = _transformationController.value.getMaxScaleOnAxis();
                    if ((scale - widget.zoomScale).abs() > 0.02) {
                      widget.onZoomScaleChanged?.call(scale);
                    }
                  },
                  onInteractionEnd: (_) {
                    _isInteractiveZooming = false;
                    widget.onZoomScaleChanged
                        ?.call(_transformationController.value.getMaxScaleOnAxis());
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: RepaintBoundary(
                      key: widget.repaintBoundaryKey,
                      child: Stack(
                        alignment: Alignment.center,
                        clipBehavior: Clip.none,
                        children: [
                          Image.file(
                            File(widget.imagePath!),
                            key: ValueKey('${widget.imagePath!}_${widget.imageRevision}'),
                            fit: BoxFit.contain,
                            filterQuality: FilterQuality.medium,
                          ),

                          // Annotations + live preview + selection chrome.
                          Positioned.fill(
                            child: MouseRegion(
                              cursor: _cursor,
                              onHover: (e) => _updateCursor(e.localPosition),
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
                                    baseImage: _baseImage,
                                    showHud: _currentAnnotation != null ||
                                        _isResizingAnnotation ||
                                        _isDraggingAnnotation,
                                  ),
                                ),
                              ),
                            ),
                          ),

                          if (_activeCropRect != null &&
                              _activeCropRect!.width > 10 &&
                              _activeCropRect!.height > 10) ...[
                            Positioned.fill(
                              child: IgnorePointer(
                                child: CustomPaint(
                                  painter: _CropOverlayPainter(cropRect: _activeCropRect!),
                                ),
                              ),
                            ),
                            _buildCropActionBar(),
                          ],

                          if (selectedBounds != Rect.zero) _buildDeleteChip(selectedBounds),
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

  Widget _buildEmptyState() {
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

  Widget _buildCropActionBar() {
    final cropRect = _activeCropRect!;
    final size = _canvasSize;

    double barTop = cropRect.bottom + 14;
    if (barTop > size.height - 50) {
      barTop = math.max(12, cropRect.top - 48);
      if (barTop < 12) barTop = math.max(12, cropRect.bottom - 48);
    }
    final barLeft =
        (cropRect.center.dx - 110).clamp(12.0, math.max(12.0, size.width - 220)).toDouble();

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
                label: const Text('Apply Crop',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                onPressed: _applyCrop,
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
  }

  Widget _buildDeleteChip(Rect selectedBounds) {
    return Positioned(
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
    );
  }
}

class _SteadyCheckerboardPainter extends CustomPainter {
  final bool isDarkMode;

  _SteadyCheckerboardPainter({required this.isDarkMode});

  @override
  void paint(Canvas canvas, Size size) {
    const squareSize = 14.0;
    final paint1 = Paint()..color = isDarkMode ? const Color(0xFF1B1917) : const Color(0xFFE8E2D9);
    final paint2 = Paint()..color = isDarkMode ? const Color(0xFF262320) : const Color(0xFFF5EFE6);

    int row = 0;
    for (double y = 0; y < size.height; y += squareSize) {
      int col = 0;
      for (double x = 0; x < size.width; x += squareSize) {
        canvas.drawRect(
          Rect.fromLTWH(x, y, math.min(squareSize, size.width - x),
              math.min(squareSize, size.height - y)),
          ((row + col) % 2 == 0) ? paint1 : paint2,
        );
        col++;
      }
      row++;
    }
  }

  @override
  bool shouldRepaint(covariant _SteadyCheckerboardPainter oldDelegate) =>
      oldDelegate.isDarkMode != isDarkMode;
}

class _CropOverlayPainter extends CustomPainter {
  final Rect cropRect;

  _CropOverlayPainter({required this.cropRect});

  @override
  void paint(Canvas canvas, Size size) {
    final fullRect =
        (Offset.zero & size).expandToInclude(cropRect).inflate(100.0);
    final path = Path()
      ..addRect(fullRect)
      ..addRect(cropRect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(path, Paint()..color = Colors.black.withValues(alpha: 0.55));

    canvas.drawRect(
      cropRect,
      Paint()
        ..color = AppColors.accent
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke,
    );

    // Rule-of-thirds guides, as used by every mainstream crop UI.
    final guidePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.28)
      ..strokeWidth = 1.0;
    for (int i = 1; i < 3; i++) {
      final dx = cropRect.left + cropRect.width * i / 3;
      final dy = cropRect.top + cropRect.height * i / 3;
      canvas.drawLine(Offset(dx, cropRect.top), Offset(dx, cropRect.bottom), guidePaint);
      canvas.drawLine(Offset(cropRect.left, dy), Offset(cropRect.right, dy), guidePaint);
    }

    const handleSize = 9.0;
    void drawSquareHandle(Offset center) {
      final rect = Rect.fromCenter(center: center, width: handleSize, height: handleSize);
      canvas.drawRect(rect.shift(const Offset(0, 1)), Paint()..color = Colors.black38);
      canvas.drawRect(rect, Paint()..color = Colors.white);
      canvas.drawRect(
        rect,
        Paint()
          ..color = AppColors.accent
          ..strokeWidth = 1.2
          ..style = PaintingStyle.stroke,
      );
    }

    for (final c in [
      cropRect.topLeft,
      cropRect.topRight,
      cropRect.bottomLeft,
      cropRect.bottomRight,
      cropRect.topCenter,
      cropRect.bottomCenter,
      cropRect.centerLeft,
      cropRect.centerRight,
    ]) {
      drawSquareHandle(c);
    }

    final tp = TextPainter(
      text: TextSpan(
        text: '${cropRect.width.round()} × ${cropRect.height.round()} px',
        style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final badgeCenter = Offset(cropRect.center.dx, cropRect.top - 16);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: badgeCenter, width: tp.width + 12, height: tp.height + 6),
        const Radius.circular(10),
      ),
      Paint()..color = AppColors.accent,
    );
    tp.paint(canvas, badgeCenter - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _CropOverlayPainter oldDelegate) =>
      oldDelegate.cropRect != cropRect;
}

class _AnnotationPainter extends CustomPainter {
  final List<Annotation> annotations;
  final Annotation? currentAnnotation;
  final String? selectedAnnotationId;
  final ui.Image? baseImage;
  final bool showHud;

  _AnnotationPainter({
    required this.annotations,
    this.currentAnnotation,
    this.selectedAnnotationId,
    this.baseImage,
    this.showHud = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Blur regions resample the real screenshot pixels, so the on-screen result
    // is identical to what the exporter writes to disk.
    final image = baseImage;
    final imageRect = image == null
        ? null
        : RenderService.imageRectInCanvas(
            imageSize: Size(image.width.toDouble(), image.height.toDouble()),
            canvasSize: size,
          );

    AnnotationRenderer.paintAll(
      canvas,
      [...annotations, ?currentAnnotation],
      baseImage: image,
      imageRect: imageRect,
    );

    if (selectedAnnotationId != null) {
      for (final ann in annotations) {
        if (ann.id == selectedAnnotationId) {
          AnnotationRenderer.paintSelection(canvas, ann);
          if (showHud) AnnotationRenderer.paintMeasurementHud(canvas, ann);
          break;
        }
      }
    }

    if (showHud && currentAnnotation != null) {
      AnnotationRenderer.paintMeasurementHud(canvas, currentAnnotation!);
    }
  }

  @override
  bool shouldRepaint(covariant _AnnotationPainter oldDelegate) {
    return !listEquals(oldDelegate.annotations, annotations) ||
        oldDelegate.currentAnnotation != currentAnnotation ||
        oldDelegate.selectedAnnotationId != selectedAnnotationId ||
        oldDelegate.baseImage != baseImage ||
        oldDelegate.showHud != showHud;
  }
}
