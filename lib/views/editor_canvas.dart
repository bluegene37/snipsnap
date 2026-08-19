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
import '../services/clipboard_service.dart';
import '../services/render_service.dart';
import '../tools/tool_handler.dart';
import '../utils/canvas_projection.dart';
import '../utils/constants.dart';
import '../utils/image_operations.dart';
import '../utils/snip_theme.dart';
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

  /// Fired when the OCR tool asks for text, with the region in **native image
  /// pixels** or null for the whole capture. The handler works in canvas
  /// space; this callback is the converted side of that boundary.
  final void Function(Rect? imageRegionPx)? onExtractText;

  /// Fired with the file path and native pixel size every time a bitmap
  /// finishes decoding. The parent stores annotations in image pixels, so it
  /// needs the same size this canvas projects through — reading it from here
  /// rather than from a persisted field is what stops the two disagreeing
  /// after any operation that rewrites the file.
  final void Function(String imagePath, Size imageSize)? onImageSizeResolved;

  /// Fired after this canvas has rewritten the capture file in place.
  ///
  /// The floating-selection paths (cut, move, delete) edit the bitmap from
  /// inside the canvas and leave the path and the pixel dimensions unchanged,
  /// so `onImageSizeResolved` early-returns and the parent has no other way to
  /// notice. Anything the parent keys off the bitmap — the OCR cache key above
  /// all — is stale until this fires.
  final VoidCallback? onImageBytesChanged;

  /// Awaited before the flood fill overwrites the source file so the caller can
  /// snapshot the original bitmap for undo.
  final Future<void> Function()? onBeforeCanvasFill;

  /// Fired when a gesture's write had to be dropped because the projection is
  /// degenerate — the bitmap has not decoded yet, or failed to decode at all.
  ///
  /// The canvas refuses such writes rather than storing raw canvas numbers as
  /// image pixels, and a stroke that silently does not persist is its own bug,
  /// so the parent surfaces this. Throttled inside the canvas: a single drag
  /// emits hundreds of live updates and must not become hundreds of toasts.
  final VoidCallback? onEditUnplaceable;
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
  final double fillTolerance;
  final bool isGlobalFill;

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
    this.onExtractText,
    this.onImageSizeResolved,
    this.onBeforeCanvasFill,
    this.onImageBytesChanged,
    this.onEditUnplaceable,
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
    this.fillTolerance = 15.0,
    this.isGlobalFill = false,
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
  curve,
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

const _freehandTools = {CanvasTool.pen, CanvasTool.highlight};

/// Tools whose annotation is created on tap-up, so a stray drag cannot spawn
/// duplicates. Their handlers still own the placement — the canvas only
/// declines to start a drag for them.
const _tapToPlaceTools = {
  CanvasTool.stepMarker,
  CanvasTool.text,
  CanvasTool.fill,
  CanvasTool.colorPicker,
};

/// Tools whose tap acts on whatever sits under the cursor. They must run
/// before the generic "clicking an annotation selects it" fallback, otherwise
/// the eyedropper and the fill bucket would only ever select — and clicking to
/// read the whole image would merely select the annotation that happens to sit
/// where the user clicked.
const _tapActsUnderCursorTools = {
  CanvasTool.fill,
  CanvasTool.colorPicker,
  CanvasTool.ocr,
};

class _EditorCanvasState extends State<EditorCanvas> implements ToolDelegate {
  final Uuid _uuid = const Uuid();
  final FocusNode _focusNode = FocusNode(debugLabel: 'EditorCanvas');
  bool _fileExists = false;
  late TransformationController _transformationController;

  /// Decoded source pixels, used to render blur/pixelate regions on screen with
  /// exactly the same code path the exporter uses.
  ui.Image? _baseImage;
  img.Image? _cachedSourceImage;
  int _baseImageToken = 0;

  /// When the parent was last told a write could not be placed. See
  /// [_reportUnplaceableEdit].
  DateTime? _lastUnplaceableReport;

  // Selection / transform state
  String? _selectedAnnotationId;
  String? _prevSelectedAnnotationId;
  bool _isDraggingAnnotation = false;
  bool _isResizingAnnotation = false;
  bool _isRotatingAnnotation = false;
  _AnnHandle _currentAnnHandle = _AnnHandle.none;

  // Marquee Selection & Cut-and-Move Floating State
  Rect? _selectionMarquee;

  /// The in-flight OCR region, in canvas coordinates, drawn while the drag is
  /// live so the user can see what will be read. Purely a preview — the
  /// authoritative rect is the handler's, and it is converted to image pixels
  /// in [onExtractText].
  Rect? _ocrRegion;
  Rect? _floatingSelectionOriginRect;
  Rect? _floatingSelectionRect;
  img.Image? _cutSelectionImage;
  ui.Image? _floatingSelectionUiImage;
  bool _hasExtractedSelection = false;
  bool _isDraggingSelection = false;
  _CropHandle _currentSelectionHandle = _CropHandle.none;
  Rect? _selectionGestureOriginRect;

  /// Geometry captured when a transform gesture begins so every frame is
  /// computed from the original shape instead of accumulating rounding drift.
  Annotation? _gestureOrigin;
  Offset _gestureStartPos = Offset.zero;

  // Crop state
  Rect? _activeCropRect;
  bool _isDraggingCrop = false;
  _CropHandle _currentCropHandle = _CropHandle.none;
  Rect? _cropOrigin;

  // Inline text editing state
  String? _editingAnnotationId;
  Offset? _inlineTextPos;
  final TextEditingController _inlineTextController = TextEditingController();
  final FocusNode _inlineTextFocusNode = FocusNode(debugLabel: 'InlineTextEditor');

  // Eyedropper Magnifier state
  Offset? _hoverPos;
  Color? _hoverColor;
  ({int x, int y})? _hoverPixelPos;

  // Drawing state
  Annotation? _currentAnnotation;
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
    _cachedSourceImage = null;
    _floatingSelectionUiImage?.dispose();
    _floatingSelectionUiImage = null;
    _focusNode.dispose();
    _inlineTextFocusNode.dispose();
    _inlineTextController.dispose();
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
      if (oldWidget.activeTool == CanvasTool.select && _hasExtractedSelection) {
        _commitFloatingSelection();
      } else {
        _floatingSelectionUiImage?.dispose();
        _floatingSelectionUiImage = null;
        _cutSelectionImage = null;
        _floatingSelectionRect = null;
        _floatingSelectionOriginRect = null;
        _hasExtractedSelection = false;
        _selectionMarquee = null;
      }

      _ocrRegion = null;

      // Drag flags owned by the canvas rather than by a handler. The
      // annotation-drag flags self-heal at the next `_onPanStart`; these do
      // not, and `_onPanEnd` may never reach the branch that clears them
      // because single-letter tool shortcuts fire mid-drag on this same
      // FocusNode. Left set, `_isDraggingSelection` makes the *next* drag
      // rebuild `_floatingSelectionRect` from a stale origin and conjure a
      // phantom selection box. Cleared here rather than in any one tool's
      // branch so every present and future tool is covered.
      _isDraggingCrop = false;
      _currentCropHandle = _CropHandle.none;
      _cropOrigin = null;
      _isDraggingSelection = false;
      _currentSelectionHandle = _CropHandle.none;
      _selectionGestureOriginRect = null;

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
      if (mounted) {
        setState(() {
          _baseImage = null;
          _cachedSourceImage = null;
        });
      }
      return;
    }

    try {
      final bytes = await File(path).readAsBytes();
      final decodedImg = img.decodeImage(bytes);
      final image = await RenderService.decodeImageFile(path);
      // A newer load (or disposal) won the race — drop this frame's native memory.
      if (!mounted || token != _baseImageToken) {
        image?.dispose();
        return;
      }
      setState(() {
        _baseImage?.dispose();
        _baseImage = image;
        _cachedSourceImage = decodedImg;
      });
      if (image != null) {
        // After the setState, never during it: the listener drives the
        // parent's own setState.
        widget.onImageSizeResolved?.call(
          path,
          Size(image.width.toDouble(), image.height.toDouble()),
        );
      }
    } catch (_) {}
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

  /// Size of the editor canvas, or [Size.zero] before it has been laid out.
  ///
  /// Zero rather than a plausible-looking default on purpose: this feeds the
  /// projection, and inventing a size silently maps every annotation against a
  /// viewport that never existed. Callers detect the degenerate case through
  /// `CanvasProjection.isValid` and decline to convert.
  Size get _canvasSize {
    final renderObj = widget.repaintBoundaryKey.currentContext?.findRenderObject();
    if (renderObj is RenderBox && renderObj.hasSize) return renderObj.size;
    return Size.zero;
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

  /// Native pixel dimensions of the loaded screenshot, or [Size.zero] before it
  /// has decoded.
  Size get _imageSize {
    final image = _baseImage;
    if (image == null) return Size.zero;
    return Size(image.width.toDouble(), image.height.toDouble());
  }

  /// The image <-> canvas mapping for the canvas as it was laid out on the
  /// previous frame. Correct for gestures (which run after layout); the paint
  /// path uses [_projectionFor] with the live constraints instead, because the
  /// render box still reports the stale size while layout is in progress.
  CanvasProjection get _projection => _projectionFor(_canvasSize);

  CanvasProjection _projectionFor(Size canvasSize) =>
      CanvasProjection(imageSize: _imageSize, canvasSize: canvasSize);

  /// `widget.annotations` are stored in image pixels; painting and hit-testing
  /// work in canvas coordinates. Memoised because it runs every build.
  List<Annotation> get _canvasAnnotations => _canvasAnnotationsFor(_projection);

  List<Annotation> _canvasAnnotationsFor(CanvasProjection p) {
    if (_canvasAnnotationsCache != null &&
        _cachedProjection == p &&
        identical(_cachedSource, widget.annotations)) {
      return _canvasAnnotationsCache!;
    }
    // An invalid projection (no image yet, or a zero-sized canvas) cannot place
    // anything, so the list passes through untouched rather than being mangled.
    final mapped = p.isValid
        ? widget.annotations.map((a) => a.mappedToCanvasSpace(p)).toList()
        : widget.annotations;
    _canvasAnnotationsCache = mapped;
    _cachedProjection = p;
    _cachedSource = widget.annotations;
    return mapped;
  }

  List<Annotation>? _canvasAnnotationsCache;
  CanvasProjection? _cachedProjection;
  List<Annotation>? _cachedSource;

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

  /// Shift-constrains the crop drag to a square. Every other tool's shift
  /// behaviour now lives in its `ToolHandler`; crop is the one drag the canvas
  /// still owns outright, because the same rect is also manipulated by the
  /// crop handles.
  Offset _constrainCropEndPoint(Offset start, Offset end) {
    if (!_isShiftDown) return end;
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final size = math.max(dx.abs(), dy.abs());
    return Offset(
      start.dx + (dx.isNegative ? -size : size),
      start.dy + (dy.isNegative ? -size : size),
    );
  }

  // ---------------------------------------------------------------------------
  // Selection helpers
  // ---------------------------------------------------------------------------

  /// The selected annotation **in canvas space** — every caller (handle
  /// hit-testing, nudging, rotation, the selection chrome) works in canvas
  /// coordinates, and `_replaceAnnotation` converts back on the way out.
  Annotation? get _selectedAnnotation {
    if (_selectedAnnotationId == null) return null;
    for (final a in _canvasAnnotations) {
      if (a.id == _selectedAnnotationId) return a;
    }
    return null;
  }

  /// Topmost annotation under [pos]. A precise pass runs first so a click
  /// inside a hollow shape reaches whatever sits under it; only if nothing is
  /// hit precisely does a bounding-box pass make large hollow shapes grabbable.
  ///
  /// Public because `ToolDelegate` declares it: the fill tool asks the canvas
  /// what it just clicked. Canvas space, like everything it returns.
  @override
  Annotation? hitTestAnnotation(Offset pos) {
    final canvasAnnotations = _canvasAnnotations;
    for (int i = canvasAnnotations.length - 1; i >= 0; i--) {
      if (AnnotationRenderer.hitTest(canvasAnnotations[i], pos)) {
        return canvasAnnotations[i];
      }
    }
    for (int i = canvasAnnotations.length - 1; i >= 0; i--) {
      if (AnnotationRenderer.hitTestBounds(canvasAnnotations[i], pos)) {
        return canvasAnnotations[i];
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

    // Curvature handle for Arrow
    if (ann.tool == CanvasTool.arrow && ann.startPoint != null && ann.endPoint != null) {
      final curvePos = ann.controlPoint ?? ((ann.startPoint! + ann.endPoint!) / 2);
      if ((local - curvePos).distance <= r + 4.0) return _AnnHandle.curve;
    }

    final rotPos = bounds.topCenter - const Offset(0, AnnotationRenderer.rotationHandleGap);
    if ((local - rotPos).distance <= r) return _AnnHandle.rotate;
    if ((local - bounds.topLeft).distance <= r) return _AnnHandle.topLeft;
    if ((local - bounds.topRight).distance <= r) return _AnnHandle.topRight;
    if ((local - bounds.bottomLeft).distance <= r) return _AnnHandle.bottomLeft;
    if ((local - bounds.bottomRight).distance <= r) return _AnnHandle.bottomRight;

    if (AnnotationRenderer.hitTest(ann, pos)) return _AnnHandle.body;
    return _AnnHandle.none;
  }

  /// Gate for every write that crosses canvas space into the parent's
  /// image-pixel storage.
  ///
  /// An invalid projection cannot map anything. Passing the annotation through
  /// unmapped would hand the parent raw canvas coordinates, which are then
  /// persisted and stamped `coordSpace: imagePixels` — wrong numbers, wrong
  /// scalars, no error, and no discriminator left to recover them. Refusing is
  /// the same choice every other boundary on this path already makes
  /// (`Annotation.withCanvasSpaceScalars`, `onExtractText`,
  /// `_insertExtractedText`).
  ///
  /// `_projection` is invalid whenever `_baseImage` is null, and `build()`
  /// puts the live gesture detector on screen as soon as the file exists. In
  /// the normal case that window is the handful of frames before the decode
  /// lands, and a stroke started that early simply does not stick. The state
  /// that actually matters is a decode that never succeeds (corrupt or
  /// unsupported file), where the canvas stays interactive forever — which is
  /// exactly why the refusal has to be audible rather than silent.
  bool _canPlaceWrite(CanvasProjection p) {
    if (p.isValid) return true;
    _reportUnplaceableEdit();
    return false;
  }

  /// Tells the parent a write was dropped, at most once every few seconds.
  /// A drag fires `_replaceAnnotation(live: true)` on every pointer move, so
  /// an unthrottled report would replace the toast hundreds of times a second.
  void _reportUnplaceableEdit() {
    final now = DateTime.now();
    final last = _lastUnplaceableReport;
    if (last != null && now.difference(last) < const Duration(seconds: 3)) {
      return;
    }
    _lastUnplaceableReport = now;
    widget.onEditUnplaceable?.call();
  }

  /// Writes [updated] — a **canvas-space** annotation — back to the parent,
  /// which stores image pixels.
  void _replaceAnnotation(Annotation updated, {required bool live}) {
    final callback =
        live ? (widget.onAnnotationsLiveUpdated ?? widget.onAnnotationsUpdated) : widget.onAnnotationsUpdated;
    if (callback == null) return;
    final index = widget.annotations.indexWhere((a) => a.id == updated.id);
    if (index == -1) return;
    final p = _projection;
    if (!_canPlaceWrite(p)) return;
    final list = List<Annotation>.from(widget.annotations);
    list[index] = updated.mappedToImageSpace(p);
    callback(list);
  }

  /// Hands a newly drawn **canvas-space** annotation to the parent in image
  /// pixels.
  void _emitAnnotation(Annotation canvasSpaceAnnotation) {
    final p = _projection;
    if (!_canPlaceWrite(p)) return;
    widget.onAnnotationAdded(canvasSpaceAnnotation.mappedToImageSpace(p));
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
    _emitAnnotation(clone);
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

    double left = origin.left;
    double top = origin.top;
    double right = origin.right;
    double bottom = origin.bottom;

    switch (_currentCropHandle) {
      case _CropHandle.move:
        left += totalDelta.dx;
        top += totalDelta.dy;
        right += totalDelta.dx;
        bottom += totalDelta.dy;
        setState(() {
          _activeCropRect = Rect.fromLTRB(left, top, right, bottom);
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
    if (right - left < minSize) {
      if (_currentCropHandle == _CropHandle.left ||
          _currentCropHandle == _CropHandle.topLeft ||
          _currentCropHandle == _CropHandle.bottomLeft) {
        left = right - minSize;
      } else {
        right = left + minSize;
      }
    }
    if (bottom - top < minSize) {
      if (_currentCropHandle == _CropHandle.top ||
          _currentCropHandle == _CropHandle.topLeft ||
          _currentCropHandle == _CropHandle.topRight) {
        top = bottom - minSize;
      } else {
        bottom = top + minSize;
      }
    }

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
  // ToolDelegate
  //
  // The single boundary between the handlers and this widget. Handlers work
  // entirely in **canvas** coordinates — that is what gestures, painting and
  // hit-testing use — while `widget.annotations` is stored in **image pixels**.
  // Every member below is therefore either a canvas-space read (`annotations`,
  // `hitTestAnnotation`) or a write that converts on the way out
  // (`_emitAnnotation`, `_replaceAnnotation`, `pushAnnotationsState`). No
  // handler ever converts anything itself.
  // ---------------------------------------------------------------------------

  /// The handler for the active tool. Cached because handlers carry per-gesture
  /// state (`_drawStart`, the accumulated freehand points) that has to survive
  /// from `onPanStart` through to `onPanEnd`; rebuilding one per callback would
  /// reset that mid-drag.
  ToolHandler? _cachedHandler;
  CanvasTool? _cachedHandlerTool;

  ToolHandler get _toolHandler {
    if (_cachedHandlerTool != widget.activeTool || _cachedHandler == null) {
      _cachedHandler = handlerFor(widget.activeTool, this);
      _cachedHandlerTool = widget.activeTool;
    }
    return _cachedHandler!;
  }

  /// The annotation a handler most recently handed to [onAnnotationAdded].
  ///
  /// Selecting a brand-new annotation has to notify the parent with the object
  /// itself: it is not in `widget.annotations` yet (the parent's setState has
  /// not run), so looking it up by id would find nothing and the property panel
  /// would not follow what was just drawn.
  Annotation? _justAddedAnnotation;

  /// Canvas-space view. Never `widget.annotations` — that list is image pixels
  /// and handing it to a handler would place every gesture against the wrong
  /// geometry.
  @override
  List<Annotation> get annotations => _canvasAnnotations;

  @override
  String? get selectedAnnotationId => _selectedAnnotationId;

  @override
  Annotation? get currentAnnotation => _currentAnnotation;

  @override
  Rect? get activeCropRect => _activeCropRect;

  @override
  Color get activeColor => widget.activeColor;

  @override
  double get strokeWidth => widget.strokeWidth;

  @override
  double get opacity => widget.opacity;

  @override
  double get fontSize => widget.fontSize;

  @override
  bool get isFilled => widget.isFilled;

  @override
  Color? get textBackgroundColor => widget.textBackgroundColor;

  @override
  Color? get fillColor => widget.fillColor;

  @override
  int get stepCounter => widget.stepCounter;

  @override
  double get blurStrength => widget.blurStrength;

  @override
  double get borderRadius => widget.borderRadius;

  @override
  ShapeKind get shapeKind => widget.shapeKind;

  @override
  LineStyle get lineStyle => widget.lineStyle;

  @override
  BlurType get blurType => widget.blurType;

  @override
  bool get isDoubleArrow => widget.isDoubleArrow;

  @override
  bool get hasShadow => widget.hasShadow;

  @override
  double get fillTolerance => widget.fillTolerance;

  @override
  bool get isGlobalFill => widget.isGlobalFill;

  @override
  bool get isShiftDown => _isShiftDown;

  @override
  bool get isAltDown => _isAltDown;

  /// Canvas space in, image pixels out.
  @override
  void onAnnotationAdded(Annotation annotation) {
    _justAddedAnnotation = annotation;
    _emitAnnotation(annotation);
  }

  @override
  void onActiveCropRectChanged(Rect? rect) => setState(() => _activeCropRect = rect);

  @override
  void onCurrentAnnotationChanged(Annotation? annotation) =>
      setState(() => _currentAnnotation = annotation);

  @override
  void onSelectedAnnotationIdChanged(String? id) {
    setState(() => _selectedAnnotationId = id);
    // Mirrors what the inline implementation did and only what it did: selecting
    // a *newly drawn* annotation told the parent, so the property panel opens on
    // it and the toolbar adopts its style. Re-selecting an existing item (the
    // fill bucket) and clearing the selection (crop) were both silent.
    final added = _justAddedAnnotation;
    _justAddedAnnotation = null;
    if (id != null && added != null && added.id == id) {
      widget.onSelectAnnotation?.call(added);
    }
  }

  @override
  void onToolSelected(CanvasTool tool) => widget.onToolSelected?.call(tool);

  @override
  void onStepCounterIncremented(int step) => widget.onStepCounterIncremented(step);

  @override
  void showTextPrompt(Offset pos) => _startInlineTextEdit(pos);

  /// A discrete edit to an existing annotation (today: the fill bucket
  /// recolouring what was clicked). The checkpoint is what makes it one undo
  /// step, matching the inline fill branch this replaced.
  @override
  void updateAnnotation(String id, Annotation updatedAnnotation) {
    _pushHistoryCheckpoint();
    _replaceAnnotation(updatedAnnotation, live: true);
  }

  /// Handlers pass canvas-space lists and the parent stores image pixels, so
  /// this converts before handing off. No handler calls it today, but the
  /// interface declares it and an unconverted implementation would be a latent
  /// coordinate bug waiting for the first caller.
  @override
  void pushAnnotationsState(List<Annotation> newAnnotations) {
    final p = _projection;
    if (!_canPlaceWrite(p)) return;
    widget.onAnnotationsUpdated?.call(
      newAnnotations.map((a) => a.mappedToImageSpace(p)).toList(),
    );
  }

  @override
  void onPerformCanvasFill(Offset pos) => _performCanvasFloodFill(pos);

  @override
  void onSampleColorFromCanvas(Offset pos) => _sampleColorAt(pos);

  /// The single crossing point between the OCR handler's canvas space and the
  /// image pixels `OcrService` crops in.
  ///
  /// An invalid projection cannot place the region anywhere — it would hand the
  /// service raw canvas numbers and crop an arbitrary rectangle of the bitmap —
  /// so nothing is requested at all rather than something wrong.
  @override
  void onExtractText(Rect? canvasRegion) {
    final p = _projection;
    if (!p.isValid) return;
    widget.onExtractText?.call(
      canvasRegion == null ? null : p.toImageRect(canvasRegion),
    );
  }

  // ---------------------------------------------------------------------------
  // Gestures
  // ---------------------------------------------------------------------------

  /// Builds the annotation for the inline text editor.
  ///
  /// Still here after the handlers took over drawing because `TextToolHandler`
  /// only raises the prompt — the annotation cannot exist until the user has
  /// typed something, which happens in `_commitInlineText`, long after the
  /// gesture ended.
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

    // The OCR tool only ever reads. Letting it fall through to the shared
    // fallbacks below would let a drag grab the annotation sitting on top of
    // the very text the user is trying to extract, and move it instead.
    if (widget.activeTool == CanvasTool.ocr) {
      setState(() {
        _selectedAnnotationId = null;
        _drawStart = pos;
        _ocrRegion = Rect.fromPoints(pos, pos);
      });
      _toolHandler.onPanStart(details, pos);
      return;
    }

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

    // Selection tool workflow
    if (widget.activeTool == CanvasTool.select) {
      // 1. If clicking active floating selection handle or body
      if (_floatingSelectionRect != null) {
        final handle = _hitTestCropRect(pos, _floatingSelectionRect!);
        if (handle != _CropHandle.none) {
          if (!_hasExtractedSelection) {
            _extractFloatingSelection();
          }
          setState(() {
            _isDraggingSelection = true;
            _currentSelectionHandle = handle;
            _selectionGestureOriginRect = _floatingSelectionRect;
          });
          return;
        } else {
          // Clicked outside floating selection -> commit it!
          _commitFloatingSelection();
        }
      }

      // 2. Check if an existing annotation was grabbed
      final hit = hitTestAnnotation(pos);
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

      // 3. Start drag marquee box on image
      setState(() {
        _selectedAnnotationId = null;
        _drawStart = pos;
        _selectionMarquee = Rect.fromPoints(pos, pos);
      });
      widget.onSelectAnnotation?.call(null);
      return;
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
          _isResizingAnnotation = !_isDraggingAnnotation &&
              !_isRotatingAnnotation &&
              handle != _AnnHandle.curve;
          _currentAnnHandle = handle;
        });
        return;
      }
    }

    // Existing items can be grabbed directly with any tool active
    final hit = hitTestAnnotation(pos);
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

    setState(() {
      _selectedAnnotationId = null;
      _isDraggingAnnotation = false;
      _isResizingAnnotation = false;
      _isRotatingAnnotation = false;
      _currentAnnHandle = _AnnHandle.none;
      _gestureOrigin = null;
    });

    // Click-to-place tools are created on tap-up so a stray drag cannot spawn
    // duplicates. Their handlers do implement `onPanStart`, so the guard has to
    // stay here rather than in the handler.
    if (_tapToPlaceTools.contains(widget.activeTool)) return;

    _drawStart = pos;
    _toolHandler.onPanStart(details, pos);
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final pos = details.localPosition;
    final totalDelta = pos - _gestureStartPos;

    // OCR produces no annotation, so it would never survive the
    // `_currentAnnotation == null` guard this method ends with.
    if (widget.activeTool == CanvasTool.ocr) {
      if (_drawStart == null) return;
      setState(() => _ocrRegion = Rect.fromPoints(_drawStart!, pos));
      _toolHandler.onPanUpdate(details, pos);
      return;
    }

    if (_isDraggingCrop) {
      _updateCropRect(totalDelta);
      return;
    }

    if (_isDraggingSelection && _selectionGestureOriginRect != null) {
      final origin = _selectionGestureOriginRect!;
      if (_currentSelectionHandle == _CropHandle.move) {
        setState(() {
          _floatingSelectionRect = origin.shift(totalDelta);
        });
      } else {
        double left = origin.left;
        double top = origin.top;
        double right = origin.right;
        double bottom = origin.bottom;
        switch (_currentSelectionHandle) {
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
          default:
            break;
        }
        const minSize = 10.0;
        if (right - left < minSize) {
          if (_currentSelectionHandle == _CropHandle.left ||
              _currentSelectionHandle == _CropHandle.topLeft ||
              _currentSelectionHandle == _CropHandle.bottomLeft) {
            left = right - minSize;
          } else {
            right = left + minSize;
          }
        }
        if (bottom - top < minSize) {
          if (_currentSelectionHandle == _CropHandle.top ||
              _currentSelectionHandle == _CropHandle.topLeft ||
              _currentSelectionHandle == _CropHandle.topRight) {
            top = bottom - minSize;
          } else {
            bottom = top + minSize;
          }
        }
        setState(() {
          _floatingSelectionRect = Rect.fromLTRB(left, top, right, bottom);
        });
      }
      return;
    }

    if (widget.activeTool == CanvasTool.select && _drawStart != null) {
      setState(() {
        _selectionMarquee = Rect.fromPoints(_drawStart!, pos);
      });
      return;
    }

    final origin = _gestureOrigin;

    if (_currentAnnHandle == _AnnHandle.curve && origin != null) {
      final local = AnnotationRenderer.toLocalSpace(origin, pos);
      _replaceAnnotation(origin.copyWith(controlPoint: local), live: true);
      return;
    }

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
      final end = _constrainCropEndPoint(_drawStart!, pos);
      setState(() => _activeCropRect = Rect.fromPoints(_drawStart!, end));
      return;
    }

    // Nothing canvas-owned claimed the gesture: it is a tool drawing.
    if (_currentAnnotation == null || _drawStart == null) return;
    _toolHandler.onPanUpdate(details, pos);
  }

  void _onPanEnd(DragEndDetails details) {
    if (widget.activeTool == CanvasTool.ocr) {
      _toolHandler.onPanEnd(details);
      // `_currentAnnotation` is cleared here for the same reason the tail of
      // this method clears it: switch to OCR *mid-drag* with a single-letter
      // shortcut and this branch is what answers mouse-up, leaving the
      // previous tool's half-drawn preview painting forever.
      setState(() {
        _ocrRegion = null;
        _currentAnnotation = null;
      });
      _drawStart = null;
      return;
    }

    if (_isDraggingCrop) {
      setState(() {
        _isDraggingCrop = false;
        _currentCropHandle = _CropHandle.none;
        _cropOrigin = null;
      });
      return;
    }

    if (_isDraggingSelection) {
      setState(() {
        _isDraggingSelection = false;
        _currentSelectionHandle = _CropHandle.none;
        _selectionGestureOriginRect = null;
      });
      return;
    }

    if (widget.activeTool == CanvasTool.select && _selectionMarquee != null) {
      final marquee = _selectionMarquee!;
      if (marquee.width >= 5 && marquee.height >= 5) {
        setState(() {
          _floatingSelectionRect = marquee;
          _floatingSelectionOriginRect = marquee;
          _hasExtractedSelection = false;
          _selectionMarquee = null;
          _drawStart = null;
        });
      } else {
        setState(() {
          _selectionMarquee = null;
          _drawStart = null;
        });
      }
      return;
    }

    if (_isRotatingAnnotation ||
        _isResizingAnnotation ||
        _isDraggingAnnotation ||
        _currentAnnHandle == _AnnHandle.curve) {
      final settled = _selectedAnnotation;
      setState(() {
        _isRotatingAnnotation = false;
        _isResizingAnnotation = false;
        _isDraggingAnnotation = false;
        _currentAnnHandle = _AnnHandle.none;
        _gestureOrigin = null;
      });
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

    // The handler decides whether the drag was big enough to keep and commits
    // it through `onAnnotationAdded`.
    _toolHandler.onPanEnd(details);

    // Then the canvas clears the in-flight preview itself, unconditionally.
    //
    // Handlers do null it on their way out, but only the handler for the tool
    // that is active *at mouse-up* runs — and the canvas owns single-letter
    // tool shortcuts on its own FocusNode (`_handleKeyEvent`), which fire
    // mid-drag. Change tool between pan start and pan end and `_toolHandler`
    // rebuilds for the new tool, whose `onPanEnd` is an empty body for text,
    // fill, colorPicker, stepMarker and select. The half-drawn shape would then
    // keep painting forever: not in the annotation list, so it cannot be
    // selected or deleted, and only the next drag replaces it.
    //
    // Clearing here rather than invalidating the cached handler on a tool
    // change is deliberate — it holds no matter which handler answers,
    // including future ones with an empty `onPanEnd`, instead of spreading the
    // invariant across `didUpdateWidget`. It is safe because every handler
    // reads `delegate.currentAnnotation` before returning, so the commit above
    // has already happened.
    setState(() => _currentAnnotation = null);
    _drawStart = null;
  }

  /// Double clicks are detected by hand
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
    final hit = hitTestAnnotation(pos);

    if (widget.activeTool == CanvasTool.select) {
      if (_floatingSelectionRect != null) {
        if (!_floatingSelectionRect!.contains(pos)) {
          _commitFloatingSelection();
        }
      }
      if (hit != null) {
        setState(() => _selectedAnnotationId = hit.id);
        widget.onSelectAnnotation?.call(hit);
      } else {
        setState(() => _selectedAnnotationId = null);
        widget.onSelectAnnotation?.call(null);
      }
      return;
    }

    if (_consumeDoubleTap(pos)) {
      // Double-click a text callout to edit it in place.
      if (hit != null && hit.tool == CanvasTool.text) {
        setState(() => _selectedAnnotationId = hit.id);
        widget.onSelectAnnotation?.call(hit);
        _startInlineTextEdit(hit.startPoint ?? pos, existing: hit);
        return;
      }
    }

    // Fill and the eyedropper act on what is under the cursor, so they run
    // before the fallback below — otherwise clicking a shape with the fill
    // bucket would merely select it.
    if (_tapActsUnderCursorTools.contains(widget.activeTool)) {
      _toolHandler.onTapUp(details, pos);
      return;
    }

    if (hit != null) {
      setState(() => _selectedAnnotationId = hit.id);
      widget.onSelectAnnotation?.call(hit);
      return;
    }

    _toolHandler.onTapUp(details, pos);
  }

  // ---------------------------------------------------------------------------
  // Inline On-Canvas Text Editing
  // ---------------------------------------------------------------------------

  void _startInlineTextEdit(Offset pos, {Annotation? existing}) {
    setState(() {
      _editingAnnotationId = existing?.id;
      _inlineTextPos = existing?.startPoint ?? pos;
      _inlineTextController.text = existing?.text ?? '';
      _inlineTextController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _inlineTextController.text.length,
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _inlineTextFocusNode.requestFocus();
    });
  }

  void _commitInlineText() {
    if (_inlineTextPos == null) return;
    final text = _inlineTextController.text.trim();
    final pos = _inlineTextPos!;
    final editingId = _editingAnnotationId;

    setState(() {
      _inlineTextPos = null;
      _editingAnnotationId = null;
    });

    if (text.isEmpty) {
      if (editingId != null) {
        widget.onAnnotationsUpdated?.call(
          widget.annotations.where((a) => a.id != editingId).toList(),
        );
        setState(() => _selectedAnnotationId = null);
        widget.onSelectAnnotation?.call(null);
      }
      _focusNode.requestFocus();
      return;
    }

    if (editingId != null) {
      // Canvas space: `_replaceAnnotation` maps back to image pixels on the way
      // out, so handing it an image-space annotation would scale it twice.
      final existing = _canvasAnnotations.where((a) => a.id == editingId).firstOrNull;
      if (existing != null) {
        _pushHistoryCheckpoint();
        _replaceAnnotation(existing.copyWith(text: text), live: true);
      }
    } else {
      final annotation = _buildAnnotationForTool(CanvasTool.text, pos)
          .copyWith(text: text, endPoint: null);
      _emitAnnotation(annotation);
      setState(() => _selectedAnnotationId = annotation.id);
      widget.onSelectAnnotation?.call(annotation);
    }
    _focusNode.requestFocus();
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
    img.Image? decoded = _cachedSourceImage;
    if (decoded == null) {
      final path = widget.imagePath;
      if (path == null || !File(path).existsSync()) return;
      try {
        decoded = img.decodeImage(await File(path).readAsBytes());
        _cachedSourceImage = decoded;
      } catch (e) {
        debugPrint('Error loading image for sample: $e');
        return;
      }
    }
    if (decoded == null) return;

    final pixelPos = _canvasPointToImagePixel(localPos, decoded.width, decoded.height);
    if (pixelPos == null) return;

    final pixel = decoded.getPixel(pixelPos.x, pixelPos.y);
    final sampled = Color.fromARGB(
      pixel.a.toInt(),
      pixel.r.toInt(),
      pixel.g.toInt(),
      pixel.b.toInt(),
    );
    final hex = '#${sampled.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
    await ClipboardService.copyText(hex);
    widget.onSampleColor?.call(sampled);
    widget.onToolSelected?.call(CanvasTool.select);
  }

  Future<ui.Image?> _imageToUiImage(img.Image image) async {
    try {
      final pngBytes = Uint8List.fromList(img.encodePng(image));
      final codec = await ui.instantiateImageCodec(pngBytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } catch (e) {
      debugPrint('Error converting image to ui.Image: $e');
      return null;
    }
  }

  Future<void> _extractFloatingSelection() async {
    if (_hasExtractedSelection) return;
    final origin = _floatingSelectionOriginRect;
    final path = widget.imagePath;
    if (origin == null || path == null || !File(path).existsSync()) return;

    try {
      img.Image? decoded = _cachedSourceImage;
      if (decoded == null) {
        decoded = img.decodeImage(await File(path).readAsBytes());
        _cachedSourceImage = decoded;
      }
      if (decoded == null) return;

      final imageRect = _imageRect;
      if (imageRect.isEmpty) return;

      final scaleX = decoded.width / imageRect.width;
      final scaleY = decoded.height / imageRect.height;

      final relLeft = origin.left - imageRect.left;
      final relTop = origin.top - imageRect.top;
      final relRight = origin.right - imageRect.left;
      final relBottom = origin.bottom - imageRect.top;

      final pxX = (relLeft * scaleX).round().clamp(0, decoded.width - 1);
      final pxY = (relTop * scaleY).round().clamp(0, decoded.height - 1);
      final pxW = ((relRight - relLeft) * scaleX).round().clamp(1, decoded.width - pxX);
      final pxH = ((relBottom - relTop) * scaleY).round().clamp(1, decoded.height - pxY);

      final beforeFill = widget.onBeforeCanvasFill;
      if (beforeFill != null) await beforeFill();

      final extracted = ImageOperations.cutRegion(
        image: decoded,
        x: pxX,
        y: pxY,
        width: pxW,
        height: pxH,
      );
      if (extracted == null) return;

      final uiImg = await _imageToUiImage(extracted);
      if (!mounted) {
        uiImg?.dispose();
        return;
      }

      await File(path).writeAsBytes(Uint8List.fromList(img.encodePng(decoded)));
      await FileImage(File(path)).evict();
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();

      setState(() {
        _cutSelectionImage = extracted;
        _floatingSelectionUiImage?.dispose();
        _floatingSelectionUiImage = uiImg;
        _hasExtractedSelection = true;
      });

      await _loadBaseImage();
      // The file just changed underneath the parent, at the same path and the
      // same pixel size, so nothing else tells it. `_deleteFloatingSelection`
      // reaches the bitmap through this method, so it is covered here too.
      if (mounted) widget.onImageBytesChanged?.call();
    } catch (e) {
      debugPrint('Error extracting floating selection: $e');
    }
  }

  Future<void> _commitFloatingSelection() async {
    if (!_hasExtractedSelection || _cutSelectionImage == null || _floatingSelectionRect == null) {
      _floatingSelectionUiImage?.dispose();
      if (mounted) {
        setState(() {
          _floatingSelectionUiImage = null;
          _cutSelectionImage = null;
          _floatingSelectionRect = null;
          _floatingSelectionOriginRect = null;
          _hasExtractedSelection = false;
        });
      }
      return;
    }

    final path = widget.imagePath;
    final currentRect = _floatingSelectionRect!;
    final cutImg = _cutSelectionImage!;
    var wroteBitmap = false;

    try {
      img.Image? decoded = _cachedSourceImage;
      if (decoded == null && path != null && File(path).existsSync()) {
        decoded = img.decodeImage(await File(path).readAsBytes());
        _cachedSourceImage = decoded;
      }
      if (decoded != null && path != null) {
        final imageRect = _imageRect;
        final scaleX = decoded.width / imageRect.width;
        final scaleY = decoded.height / imageRect.height;

        final relLeft = currentRect.left - imageRect.left;
        final relTop = currentRect.top - imageRect.top;
        final relRight = currentRect.right - imageRect.left;
        final relBottom = currentRect.bottom - imageRect.top;

        final dstX = (relLeft * scaleX).round();
        final dstY = (relTop * scaleY).round();
        final dstW = ((relRight - relLeft) * scaleX).round();
        final dstH = ((relBottom - relTop) * scaleY).round();

        ImageOperations.pasteRegion(
          destinationImage: decoded,
          subImage: cutImg,
          dstX: dstX,
          dstY: dstY,
          dstWidth: dstW,
          dstHeight: dstH,
        );

        await File(path).writeAsBytes(Uint8List.fromList(img.encodePng(decoded)));
        await FileImage(File(path)).evict();
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
        wroteBitmap = true;
      }
    } catch (e) {
      debugPrint('Error committing floating selection: $e');
    } finally {
      _floatingSelectionUiImage?.dispose();
      if (mounted) {
        setState(() {
          _floatingSelectionUiImage = null;
          _cutSelectionImage = null;
          _floatingSelectionRect = null;
          _floatingSelectionOriginRect = null;
          _hasExtractedSelection = false;
        });
        await _loadBaseImage();
      }
      // Only when the paste actually reached the file — an early bail or a
      // decode failure leaves the bitmap exactly as the parent already knows
      // it, and a spurious bump would throw away a valid OCR cache.
      if (wroteBitmap && mounted) widget.onImageBytesChanged?.call();
    }
  }

  Future<void> _deleteFloatingSelection() async {
    if (_floatingSelectionRect == null) return;
    if (!_hasExtractedSelection) {
      await _extractFloatingSelection();
    }
    _floatingSelectionUiImage?.dispose();
    setState(() {
      _floatingSelectionUiImage = null;
      _cutSelectionImage = null;
      _floatingSelectionRect = null;
      _floatingSelectionOriginRect = null;
      _hasExtractedSelection = false;
    });
  }

  Future<void> _copyFloatingSelectionToClipboard({bool cut = false}) async {
    if (_floatingSelectionRect == null) return;
    if (!_hasExtractedSelection) {
      await _extractFloatingSelection();
    }
    if (_cutSelectionImage == null) return;

    try {
      final pngBytes = Uint8List.fromList(img.encodePng(_cutSelectionImage!));
      final tempDir = Directory.systemTemp;
      final tempFile = File('${tempDir.path}/snipsnap_sel_${DateTime.now().millisecondsSinceEpoch}.png');
      await tempFile.writeAsBytes(pngBytes);
      await ClipboardService.copyImageToClipboard(tempFile.path);

      if (cut) {
        await _deleteFloatingSelection();
      }
    } catch (e) {
      debugPrint('Error copying selection to clipboard: $e');
    }
  }

  Future<void> _performCanvasFloodFill(Offset localPos) async {
    final path = widget.imagePath;
    if (path == null || !File(path).existsSync()) return;
    try {
      img.Image? decoded = _cachedSourceImage;
      if (decoded == null) {
        decoded = img.decodeImage(await File(path).readAsBytes());
        _cachedSourceImage = decoded;
      }
      if (decoded == null) return;

      final pixelPos = _canvasPointToImagePixel(localPos, decoded.width, decoded.height);
      if (pixelPos == null) return;

      // Snapshot the pre-fill bitmap *before* it is overwritten for undo.
      final beforeFill = widget.onBeforeCanvasFill;
      if (beforeFill != null) await beforeFill();

      final modified = ImageOperations.floodFill(
        image: decoded,
        startX: pixelPos.x,
        startY: pixelPos.y,
        fillColor: widget.activeColor,
        tolerancePercent: widget.fillTolerance,
        opacity: widget.opacity,
        isGlobal: widget.isGlobalFill,
      );

      if (!modified) return;

      final pngBytes = Uint8List.fromList(img.encodePng(decoded));
      await File(path).writeAsBytes(pngBytes);
      await FileImage(File(path)).evict();
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();

      await _loadBaseImage();
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
      if (_floatingSelectionRect != null) {
        _deleteFloatingSelection();
        return KeyEventResult.handled;
      }
      if (_selectedAnnotationId != null) {
        _deleteSelectedAnnotation();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.escape) {
      if (_floatingSelectionRect != null) {
        _commitFloatingSelection();
        return KeyEventResult.handled;
      }
      setState(() {
        _selectedAnnotationId = null;
        _activeCropRect = null;
        _currentAnnotation = null;
        _drawStart = null;
        _selectionMarquee = null;
      });
      widget.onSelectAnnotation?.call(null);
      widget.onToolSelected?.call(CanvasTool.select);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      if (_floatingSelectionRect != null) {
        _commitFloatingSelection();
        return KeyEventResult.handled;
      }
      if (widget.activeTool == CanvasTool.crop && _activeCropRect != null) {
        _applyCrop();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    // Nudge the selection with the arrow keys; Shift jumps 10px at a time.
    final nudges = <LogicalKeyboardKey, Offset>{
      LogicalKeyboardKey.arrowLeft: const Offset(-1, 0),
      LogicalKeyboardKey.arrowRight: const Offset(1, 0),
      LogicalKeyboardKey.arrowUp: const Offset(0, -1),
      LogicalKeyboardKey.arrowDown: const Offset(0, 1),
    };
    final nudge = nudges[key];
    if (nudge != null) {
      if (_floatingSelectionRect != null) {
        if (!_hasExtractedSelection) {
          _extractFloatingSelection();
        }
        setState(() {
          _floatingSelectionRect =
              _floatingSelectionRect!.shift(nudge * (_isShiftDown ? 10.0 : 1.0));
        });
        return KeyEventResult.handled;
      }
      if (_selectedAnnotationId == null) return KeyEventResult.ignored;
      _nudgeSelectedAnnotation(nudge * (_isShiftDown ? 10.0 : 1.0));
      return KeyEventResult.handled;
    }

    if (_isCommandDown) {
      if (key == LogicalKeyboardKey.keyC) {
        if (_floatingSelectionRect != null) {
          _copyFloatingSelectionToClipboard(cut: false);
          return KeyEventResult.handled;
        }
      }
      if (key == LogicalKeyboardKey.keyX) {
        if (_floatingSelectionRect != null) {
          _copyFloatingSelectionToClipboard(cut: true);
          return KeyEventResult.handled;
        }
      }
      if (key == LogicalKeyboardKey.keyD) {
        _duplicateSelectedAnnotation();
        return KeyEventResult.handled;
      }
      // Every other Cmd/Ctrl chord belongs to the app-level shortcut handler.
      return KeyEventResult.ignored;
    }

    if (event is KeyRepeatEvent) return KeyEventResult.ignored;

    final toolKeys = <LogicalKeyboardKey, CanvasTool>{
      LogicalKeyboardKey.keyV: CanvasTool.select,
      LogicalKeyboardKey.keyS: CanvasTool.select,
      LogicalKeyboardKey.keyP: CanvasTool.pen,
      LogicalKeyboardKey.keyL: CanvasTool.line,
      LogicalKeyboardKey.keyA: CanvasTool.arrow,
      LogicalKeyboardKey.keyR: CanvasTool.shape,
      LogicalKeyboardKey.keyU: CanvasTool.shape,
      LogicalKeyboardKey.keyH: CanvasTool.highlight,
      LogicalKeyboardKey.keyT: CanvasTool.text,
      LogicalKeyboardKey.keyN: CanvasTool.stepMarker,
      LogicalKeyboardKey.digit1: CanvasTool.stepMarker,
      LogicalKeyboardKey.keyB: CanvasTool.blur,
      LogicalKeyboardKey.keyM: CanvasTool.ruler,
      LogicalKeyboardKey.keyG: CanvasTool.fill,
      LogicalKeyboardKey.keyI: CanvasTool.colorPicker,
      LogicalKeyboardKey.keyC: CanvasTool.crop,
      LogicalKeyboardKey.keyE: CanvasTool.ocr,
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
      case _AnnHandle.curve:
        return SystemMouseCursors.grab;
      case _AnnHandle.body:
        return SystemMouseCursors.move;
      case _AnnHandle.none:
        return SystemMouseCursors.basic;
    }
  }

  void _updateCursor(Offset pos) {
    if (widget.activeTool == CanvasTool.colorPicker) {
      final cached = _cachedSourceImage;
      if (cached != null) {
        final pixelPos = _canvasPointToImagePixel(pos, cached.width, cached.height);
        if (pixelPos != null) {
          final pixel = cached.getPixel(pixelPos.x, pixelPos.y);
          final color = Color.fromARGB(
            pixel.a.toInt(),
            pixel.r.toInt(),
            pixel.g.toInt(),
            pixel.b.toInt(),
          );
          setState(() {
            _hoverPos = pos;
            _hoverColor = color;
            _hoverPixelPos = pixelPos;
          });
        } else {
          if (_hoverPos != null) setState(() => _hoverPos = null);
        }
      }
    } else {
      if (_hoverPos != null) setState(() => _hoverPos = null);
    }

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
      if (_floatingSelectionRect != null) {
        final handle = _hitTestCropRect(pos, _floatingSelectionRect!);
        next = switch (handle) {
          _CropHandle.move => SystemMouseCursors.move,
          _CropHandle.topLeft || _CropHandle.bottomRight => SystemMouseCursors.resizeUpLeftDownRight,
          _CropHandle.topRight || _CropHandle.bottomLeft => SystemMouseCursors.resizeUpRightDownLeft,
          _CropHandle.top || _CropHandle.bottom => SystemMouseCursors.resizeUpDown,
          _CropHandle.left || _CropHandle.right => SystemMouseCursors.resizeLeftRight,
          _CropHandle.none =>
            hitTestAnnotation(pos) != null ? SystemMouseCursors.move : SystemMouseCursors.precise,
        };
      } else {
        next = hitTestAnnotation(pos) != null ? SystemMouseCursors.move : SystemMouseCursors.precise;
      }
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

    final t = SnipTheme.of(context);
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
            // Solid workspace background (Snagit-style)
            Positioned.fill(
              child: Container(
                color: t.canvas,
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
                          // Checkerboard directly under the image (revealed under transparent PNG pixels)
                          Positioned.fill(
                            child: ClipRect(
                              child: CustomPaint(
                                painter: _SteadyCheckerboardPainter(theme: t),
                              ),
                            ),
                          ),

                          Image.file(
                            File(widget.imagePath!),
                            key: ValueKey('${widget.imagePath!}_${widget.imageRevision}'),
                            fit: BoxFit.contain,
                            filterQuality: FilterQuality.medium,
                          ),

                          // Annotations + live preview + selection chrome.
                          //
                          // LayoutBuilder is load-bearing: nothing in this
                          // subtree depends on MediaQuery, so a bare window
                          // resize never rebuilds this widget. Without it the
                          // painter would keep the canvas-space annotations
                          // derived from the *old* viewport while painting at
                          // the new size — precisely the drift this change
                          // exists to remove. It also gives the true canvas
                          // size, which `_canvasSize` cannot during layout.
                          Positioned.fill(
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                final projection =
                                    _projectionFor(constraints.biggest);
                                return MouseRegion(
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
                                        annotations:
                                            _canvasAnnotationsFor(projection),
                                        pixelScale: projection.scale,
                                        currentAnnotation: _currentAnnotation,
                                        selectedAnnotationId: _selectedAnnotationId,
                                        editingAnnotationId: _editingAnnotationId,
                                        baseImage: _baseImage,
                                        showHud: _currentAnnotation != null ||
                                            _isResizingAnnotation ||
                                            _isDraggingAnnotation,
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),

                          // Floating Selection Overlay (Marquee / Cut-and-Move)
                          if (widget.activeTool == CanvasTool.select &&
                              (_selectionMarquee != null || _floatingSelectionRect != null)) ...[
                            Positioned.fill(
                              child: IgnorePointer(
                                child: CustomPaint(
                                  painter: _FloatingSelectionPainter(
                                    theme: t,
                                    marqueeRect: _selectionMarquee,
                                    floatingRect: _floatingSelectionRect,
                                    floatingImage: _floatingSelectionUiImage,
                                    nativeImageSize: _baseImage != null
                                        ? Size(_baseImage!.width.toDouble(),
                                            _baseImage!.height.toDouble())
                                        : null,
                                    imageRect: _imageRect,
                                  ),
                                ),
                              ),
                            ),
                          ],

                          if (_activeCropRect != null &&
                              _activeCropRect!.width > 10 &&
                              _activeCropRect!.height > 10) ...[
                            Positioned.fill(
                              child: IgnorePointer(
                                child: CustomPaint(
                                  painter: _CropOverlayPainter(
                                    theme: t,
                                    cropRect: _activeCropRect!,
                                    imageRect: _imageRect,
                                    nativeImageSize: _baseImage != null
                                        ? Size(_baseImage!.width.toDouble(),
                                            _baseImage!.height.toDouble())
                                        : null,
                                  ),
                                ),
                              ),
                            ),
                            _buildCropActionBar(),
                          ],

                          if (selectedBounds != Rect.zero) _buildDeleteChip(selectedBounds),

                          // Inline on-canvas text editing overlay
                          if (_inlineTextPos != null) _buildInlineTextEditor(),

                          // OCR region marquee, drawn while the drag is live.
                          if (widget.activeTool == CanvasTool.ocr &&
                              _ocrRegion != null)
                            Positioned.fromRect(
                              rect: _ocrRegion!,
                              child: IgnorePointer(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: t.ink.withValues(alpha: 0.1),
                                    border: Border.all(
                                      color: t.border,
                                      width: 1.5,
                                    ),
                                  ),
                                ),
                              ),
                            ),

                          // Eyedropper magnifier loupe HUD
                          if (widget.activeTool == CanvasTool.colorPicker &&
                              _hoverPos != null &&
                              _hoverColor != null)
                            _buildMagnifierLoupe(),
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
    final t = SnipTheme.of(context);

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: t.surface,
              shape: BoxShape.circle,
              border: Border.all(color: t.border),
            ),
            child: Icon(Icons.add_a_photo_rounded, size: 56, color: t.emphasis),
          ),
          const SizedBox(height: 16),
          Text(
            'No Screenshot Selected',
            style: TextStyle(color: t.ink, fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            'Click "Snip" in the top bar to capture screen area, or open an existing image.',
            style: TextStyle(color: t.inkMuted, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildCropActionBar() {
    final t = SnipTheme.of(context);
    final cropRect = _activeCropRect!;
    final size = _canvasSize;

    double barTop = cropRect.bottom + 14;
    if (barTop > size.height - 50) {
      barTop = math.max(12, cropRect.top - 48);
      if (barTop < 12) barTop = math.max(12, cropRect.bottom - 48);
    }
    final barLeft =
        (cropRect.center.dx - 110).clamp(12.0, math.max(12.0, size.width - 220)).toDouble();

    final imageRect = _imageRect;
    final isExpanded = cropRect.left < imageRect.left - 1 ||
        cropRect.top < imageRect.top - 1 ||
        cropRect.right > imageRect.right + 1 ||
        cropRect.bottom > imageRect.bottom + 1;

    return Positioned(
      left: barLeft,
      top: barTop,
      child: Material(
        color: t.surface,
        elevation: 8,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: t.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: t.surfaceRaised,
                  foregroundColor: t.emphasis,
                  side: BorderSide(color: t.emphasis, width: 1.2),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                icon: const Icon(Icons.check_rounded, size: 16),
                label: Text(
                  isExpanded ? 'Apply Expansion' : 'Apply Crop',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                ),
                onPressed: _applyCrop,
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: t.ink,
                  side: BorderSide(color: t.border),
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
    final t = SnipTheme.of(context);
    return Positioned(
      left: math.max(0, selectedBounds.topRight.dx - 10),
      top: math.max(0, selectedBounds.topRight.dy - 14),
      child: Tooltip(
        message: 'Delete selected annotation (Delete / Backspace)',
        child: Material(
          color: t.danger,
          elevation: 4,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: _deleteSelectedAnnotation,
            child: Padding(
              padding: const EdgeInsets.all(5),
              child: Icon(Icons.close_rounded, size: 14, color: t.onDanger),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInlineTextEditor() {
    final pos = _inlineTextPos;
    if (pos == null) return const SizedBox.shrink();

    final t = SnipTheme.of(context);
    final showBg = widget.isFilled &&
        widget.textBackgroundColor != null &&
        widget.textBackgroundColor!.a > 0;

    return Positioned(
      left: math.max(10, pos.dx - 8),
      top: math.max(10, pos.dy - 6),
      child: Material(
        color: Colors.transparent,
        child: Container(
          constraints: const BoxConstraints(minWidth: 120, maxWidth: 450),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: showBg ? (widget.textBackgroundColor ?? Colors.black87) : t.surface,
            borderRadius: BorderRadius.circular(widget.borderRadius.clamp(4.0, 16.0)),
            border: Border.all(color: t.ink, width: 2.0),
            boxShadow: const [
              BoxShadow(color: Colors.black38, blurRadius: 8, offset: Offset(0, 3)),
            ],
          ),
          child: IntrinsicWidth(
            child: TextField(
              focusNode: _inlineTextFocusNode,
              controller: _inlineTextController,
              autofocus: true,
              maxLines: null,
              keyboardType: TextInputType.multiline,
              style: TextStyle(
                color: widget.activeColor,
                fontSize: widget.fontSize,
                fontWeight: FontWeight.w600,
                height: 1.25,
              ),
              decoration: InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
                hintText: 'Type text here...',
                hintStyle: TextStyle(color: t.inkMuted, fontSize: 13),
              ),
              onSubmitted: (_) => _commitInlineText(),
              onTapOutside: (_) => _commitInlineText(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMagnifierLoupe() {
    final t = SnipTheme.of(context);
    final pos = _hoverPos;
    final color = _hoverColor;
    final pixelPos = _hoverPixelPos;
    final cached = _cachedSourceImage;
    if (pos == null || color == null || pixelPos == null || cached == null) {
      return const SizedBox.shrink();
    }

    final hex = '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
    final rgb = 'RGB(${(color.r * 255).round()}, ${(color.g * 255).round()}, ${(color.b * 255).round()})';

    final size = _canvasSize;
    double left = pos.dx + 20;
    double top = pos.dy - 120;
    if (left + 120 > size.width) left = pos.dx - 120;
    if (top < 10) top = pos.dy + 25;

    return Positioned(
      left: left.clamp(10.0, math.max(10.0, size.width - 130)),
      top: top.clamp(10.0, math.max(10.0, size.height - 150)),
      child: IgnorePointer(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Circular 9x9 Zoom Grid Loupe
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: t.ink, width: 2.5),
                boxShadow: const [
                  BoxShadow(color: Colors.black45, blurRadius: 8, offset: Offset(0, 3)),
                ],
              ),
              child: ClipOval(
                child: CustomPaint(
                  size: const Size(80, 80),
                  painter: _LoupeGridPainter(
                    theme: t,
                    sourceImage: cached,
                    centerPixel: pixelPos,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 5),
            // Color readout badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: t.surfaceRaised,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: t.border),
                boxShadow: const [
                  BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2)),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(color: t.ringOn(color), width: 0.8),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        hex,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.bold,
                          fontFamily: 'monospace',
                          color: t.ink,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 1),
                  Text(
                    rgb,
                    style: TextStyle(
                      fontSize: 9,
                      color: t.inkMuted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SteadyCheckerboardPainter extends CustomPainter {
  final SnipTheme theme;

  _SteadyCheckerboardPainter({required this.theme});

  @override
  void paint(Canvas canvas, Size size) {
    const squareSize = 14.0;
    // Neutral, low-contrast panel-on-panel pair in both modes — the
    // checkerboard just needs to read as "transparent," not draw attention.
    final paint1 = Paint()..color = theme.surface;
    final paint2 = Paint()..color = theme.surfaceRaised;

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
      oldDelegate.theme != theme;
}

class _CropOverlayPainter extends CustomPainter {
  final Rect cropRect;
  final Rect imageRect;
  final Size? nativeImageSize;
  final SnipTheme theme;

  _CropOverlayPainter({
    required this.theme,
    required this.cropRect,
    required this.imageRect,
    this.nativeImageSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Dimming mask on outside of cropRect. `SnipTheme.scrim` is
    // deliberately mode-invariant — see its own doc comment — so the mask
    // never flips polarity in dark mode.
    final fullRect = (Offset.zero & size).expandToInclude(cropRect).inflate(200.0);
    final path = Path()
      ..addRect(fullRect)
      ..addRect(cropRect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(path, Paint()..color = SnipTheme.scrim);

    // 2. If cropRect extends outside imageRect, render transparent checkerboard grid like Snagit!
    if (cropRect.left < imageRect.left ||
        cropRect.top < imageRect.top ||
        cropRect.right > imageRect.right ||
        cropRect.bottom > imageRect.bottom) {
      final expandedPath = Path()
        ..addRect(cropRect)
        ..addRect(imageRect.intersect(cropRect));
      expandedPath.fillType = PathFillType.evenOdd;

      canvas.save();
      canvas.clipPath(expandedPath);
      _drawCheckerboardGrid(canvas, cropRect, theme);
      canvas.restore();
    }

    // 3. Draw original image boundary if cropRect is adjusted. This sits on
    // top of the mode-invariant scrim (or arbitrary image content, once
    // expanded past it) rather than on app chrome, so it stays a fixed light
    // mark for the same reason `SnipTheme.scrim` itself stays fixed — a
    // mode-flipping `ink` would go near-black in light mode and vanish
    // against the always-dark scrim.
    if (cropRect != imageRect && imageRect.width > 0 && imageRect.height > 0) {
      final origBorderPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.7)
        ..strokeWidth = 1.0
        ..style = PaintingStyle.stroke;
      canvas.drawRect(imageRect, origBorderPaint);
    }

    // 4. Crop border. Skeleton has no accent hue left to guarantee this reads
    // against arbitrary screenshot content, so it is drawn as a matched
    // ink/onActive pair — a lighter halo behind a darker line, or the
    // reverse in dark mode — so at least one of the two always contrasts
    // with whatever is underneath.
    canvas.drawRect(
      cropRect,
      Paint()
        ..color = theme.onActive
        ..strokeWidth = 3.4
        ..style = PaintingStyle.stroke,
    );
    canvas.drawRect(
      cropRect,
      Paint()
        ..color = theme.ink
        ..strokeWidth = 1.8
        ..style = PaintingStyle.stroke,
    );

    // 5. Rule-of-thirds guides — subtle helper lines over live image content;
    // kept fixed for the same reason as the original-boundary stroke above.
    final guidePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.28)
      ..strokeWidth = 1.0;
    for (int i = 1; i < 3; i++) {
      final dx = cropRect.left + cropRect.width * i / 3;
      final dy = cropRect.top + cropRect.height * i / 3;
      canvas.drawLine(Offset(dx, cropRect.top), Offset(dx, cropRect.bottom), guidePaint);
      canvas.drawLine(Offset(cropRect.left, dy), Offset(cropRect.right, dy), guidePaint);
    }

    // 6. 8 Square handles. A physical drop shadow (literal, not themed — it
    // is a depth cue, not a state signal) plus an ink fill ringed in the
    // opposite mark tone (onActive), so the ring always contrasts with its
    // own fill regardless of mode — the same guaranteed-contrast pairing
    // `SnipTheme.ringOn` documents, applied at draw time since a plain
    // `ink` handle over a screenshot close to `ink`'s own tone is exactly
    // the invisible-handle bug this pairing avoids.
    const handleSize = 9.0;
    void drawSquareHandle(Offset center) {
      final rect = Rect.fromCenter(center: center, width: handleSize, height: handleSize);
      canvas.drawRect(rect.shift(const Offset(0, 1)), Paint()..color = Colors.black45);
      canvas.drawRect(rect, Paint()..color = theme.ink);
      canvas.drawRect(
        rect,
        Paint()
          ..color = theme.onActive
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

    // 7. Dimensions badge — the same "ink mark plate, onActive knockout
    // text" pattern used elsewhere for chrome badges.
    int pixelW = cropRect.width.round();
    int pixelH = cropRect.height.round();
    if (nativeImageSize != null && imageRect.width > 0) {
      final scale = nativeImageSize!.width / imageRect.width;
      pixelW = (cropRect.width * scale).round();
      pixelH = (cropRect.height * scale).round();
    }

    final tp = TextPainter(
      text: TextSpan(
        text: '$pixelW × $pixelH px',
        style: TextStyle(color: theme.onActive, fontSize: 11, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final badgeCenter = Offset(cropRect.center.dx, math.max(16, cropRect.top - 16));
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: badgeCenter, width: tp.width + 12, height: tp.height + 6),
        const Radius.circular(10),
      ),
      Paint()..color = theme.ink,
    );
    tp.paint(canvas, badgeCenter - Offset(tp.width / 2, tp.height / 2));
  }

  static void _drawCheckerboardGrid(Canvas canvas, Rect rect, SnipTheme theme) {
    const squareSize = 14.0;
    final p1 = Paint()..color = theme.surface;
    final p2 = Paint()..color = theme.surfaceRaised;

    final startX = (rect.left / squareSize).floor() * squareSize;
    final startY = (rect.top / squareSize).floor() * squareSize;

    for (double y = startY; y < rect.bottom; y += squareSize) {
      for (double x = startX; x < rect.right; x += squareSize) {
        final r = Rect.fromLTWH(
          math.max(x, rect.left),
          math.max(y, rect.top),
          math.min(squareSize, rect.right - math.max(x, rect.left)),
          math.min(squareSize, rect.bottom - math.max(y, rect.top)),
        );
        if (r.width > 0 && r.height > 0) {
          final colIdx = (x / squareSize).round();
          final rowIdx = (y / squareSize).round();
          canvas.drawRect(r, (colIdx + rowIdx) % 2 == 0 ? p1 : p2);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _CropOverlayPainter oldDelegate) =>
      oldDelegate.cropRect != cropRect ||
      oldDelegate.imageRect != imageRect ||
      oldDelegate.theme != theme;
}

class _FloatingSelectionPainter extends CustomPainter {
  final SnipTheme theme;
  final Rect? marqueeRect;
  final Rect? floatingRect;
  final ui.Image? floatingImage;
  final Size? nativeImageSize;
  final Rect? imageRect;

  _FloatingSelectionPainter({
    required this.theme,
    this.marqueeRect,
    this.floatingRect,
    this.floatingImage,
    this.nativeImageSize,
    this.imageRect,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = floatingRect ?? marqueeRect;
    if (rect == null || rect.width < 1 || rect.height < 1) return;

    // 1. If we have a floating extracted bitmap, render it
    if (floatingImage != null && floatingRect != null) {
      canvas.save();
      final srcRect = Rect.fromLTWH(
        0,
        0,
        floatingImage!.width.toDouble(),
        floatingImage!.height.toDouble(),
      );
      canvas.drawImageRect(
        floatingImage!,
        srcRect,
        floatingRect!,
        Paint()..filterQuality = FilterQuality.medium,
      );
      canvas.restore();
    } else if (marqueeRect != null) {
      canvas.drawRect(
        marqueeRect!,
        Paint()..color = theme.ink.withValues(alpha: 0.12),
      );
    }

    // 2. Dashed Marquee / Selection Boundary Border. Skeleton has no accent
    // hue to guarantee this reads against arbitrary screenshot content, so —
    // like the crop border — it is a matched ink/onActive pair rather than a
    // single mark that could blend into similarly-toned image content.
    final borderPaint = Paint()
      ..color = theme.ink
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;

    final echoBorderPaint = Paint()
      ..color = theme.onActive
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;

    _drawDashedRect(canvas, rect, borderPaint, echoBorderPaint);

    // 3. 8 Resize Handles — same physical-shadow + ink-fill + onActive-ring
    // treatment as the crop overlay's handles, for the same reason: these
    // are grabbable marks over arbitrary image content, not chrome over our
    // own panel background.
    if (floatingRect != null) {
      const handleSize = 9.0;
      void drawSquareHandle(Offset center) {
        final hRect = Rect.fromCenter(center: center, width: handleSize, height: handleSize);
        canvas.drawRect(hRect.shift(const Offset(0, 1)), Paint()..color = Colors.black38);
        canvas.drawRect(hRect, Paint()..color = theme.ink);
        canvas.drawRect(
          hRect,
          Paint()
            ..color = theme.onActive
            ..strokeWidth = 1.4
            ..style = PaintingStyle.stroke,
        );
      }

      for (final c in [
        rect.topLeft,
        rect.topRight,
        rect.bottomLeft,
        rect.bottomRight,
        rect.topCenter,
        rect.bottomCenter,
        rect.centerLeft,
        rect.centerRight,
      ]) {
        drawSquareHandle(c);
      }
    }

    // 4. Dimensions Pill Badge — ink mark plate, onActive knockout text.
    int pixelW = rect.width.round();
    int pixelH = rect.height.round();
    if (nativeImageSize != null && imageRect != null && imageRect!.width > 0) {
      final scale = nativeImageSize!.width / imageRect!.width;
      pixelW = (rect.width * scale).round();
      pixelH = (rect.height * scale).round();
    }

    final tp = TextPainter(
      text: TextSpan(
        text: '$pixelW × $pixelH px',
        style: TextStyle(color: theme.onActive, fontSize: 11, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final badgeCenter = Offset(rect.center.dx, rect.top - 16);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: badgeCenter, width: tp.width + 12, height: tp.height + 6),
        const Radius.circular(10),
      ),
      Paint()..color = theme.ink,
    );
    tp.paint(canvas, badgeCenter - Offset(tp.width / 2, tp.height / 2));
  }

  void _drawDashedRect(Canvas canvas, Rect rect, Paint paint, Paint shadowPaint) {
    const dashWidth = 5.0;
    const dashSpace = 4.0;

    void drawDashedLine(Offset start, Offset end) {
      final dx = end.dx - start.dx;
      final dy = end.dy - start.dy;
      final distance = math.sqrt(dx * dx + dy * dy);
      if (distance <= 0) return;
      final ux = dx / distance;
      final uy = dy / distance;

      double current = 0.0;
      bool draw = true;
      while (current < distance) {
        final length = math.min(draw ? dashWidth : dashSpace, distance - current);
        if (draw) {
          final p1 = Offset(start.dx + ux * current, start.dy + uy * current);
          final p2 = Offset(p1.dx + ux * length, p1.dy + uy * length);
          canvas.drawLine(
              p1 + const Offset(0.5, 0.5), p2 + const Offset(0.5, 0.5), shadowPaint);
          canvas.drawLine(p1, p2, paint);
        }
        current += length;
        draw = !draw;
      }
    }

    drawDashedLine(rect.topLeft, rect.topRight);
    drawDashedLine(rect.topRight, rect.bottomRight);
    drawDashedLine(rect.bottomRight, rect.bottomLeft);
    drawDashedLine(rect.bottomLeft, rect.topLeft);
  }

  @override
  // Already unconditional, so a theme change (like every other change) is
  // covered without inspecting `oldDelegate.theme` explicitly.
  bool shouldRepaint(covariant _FloatingSelectionPainter oldDelegate) => true;
}

class _AnnotationPainter extends CustomPainter {
  final List<Annotation> annotations;
  final Annotation? currentAnnotation;
  final String? selectedAnnotationId;
  final String? editingAnnotationId;
  final ui.Image? baseImage;
  final bool showHud;

  /// Image pixels per canvas unit, for the ruler's measurement readout. The
  /// painter cannot derive it — the State owns the projection — so it is passed
  /// in from `build`.
  final double pixelScale;

  _AnnotationPainter({
    required this.annotations,
    required this.pixelScale,
    this.currentAnnotation,
    this.selectedAnnotationId,
    this.editingAnnotationId,
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

    final visibleAnnotations = editingAnnotationId != null
        ? annotations.where((a) => a.id != editingAnnotationId).toList()
        : annotations;

    AnnotationRenderer.paintAll(
      canvas,
      [...visibleAnnotations, ?currentAnnotation],
      baseImage: image,
      imageRect: imageRect,
      pixelScale: pixelScale,
    );

    if (selectedAnnotationId != null && selectedAnnotationId != editingAnnotationId) {
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
        oldDelegate.pixelScale != pixelScale ||
        oldDelegate.currentAnnotation != currentAnnotation ||
        oldDelegate.selectedAnnotationId != selectedAnnotationId ||
        oldDelegate.editingAnnotationId != editingAnnotationId ||
        oldDelegate.baseImage != baseImage ||
        oldDelegate.showHud != showHud;
  }
}

class _LoupeGridPainter extends CustomPainter {
  final SnipTheme theme;
  final img.Image sourceImage;
  final ({int x, int y}) centerPixel;

  _LoupeGridPainter({required this.theme, required this.sourceImage, required this.centerPixel});

  @override
  void paint(Canvas canvas, Size size) {
    const gridCount = 9; // 9x9 zoomed pixel grid
    final cellSize = size.width / gridCount;
    const halfGrid = gridCount ~/ 2;

    for (int dy = -halfGrid; dy <= halfGrid; dy++) {
      for (int dx = -halfGrid; dx <= halfGrid; dx++) {
        final sampleX = (centerPixel.x + dx).clamp(0, sourceImage.width - 1);
        final sampleY = (centerPixel.y + dy).clamp(0, sourceImage.height - 1);
        final pixel = sourceImage.getPixel(sampleX, sampleY);

        final cellColor = Color.fromARGB(
          pixel.a.toInt(),
          pixel.r.toInt(),
          pixel.g.toInt(),
          pixel.b.toInt(),
        );

        final cellRect = Rect.fromLTWH(
          (dx + halfGrid) * cellSize,
          (dy + halfGrid) * cellSize,
          cellSize + 0.5,
          cellSize + 0.5,
        );

        canvas.drawRect(cellRect, Paint()..color = cellColor);

        // Grid cell outline — a faint, non-interactive separator between
        // sampled-pixel cells. Kept fixed rather than theme-driven for the
        // same reason as the crop overlay's rule-of-thirds guides: it sits
        // directly on arbitrary sampled image colour, and its job is only to
        // be a barely-visible hint of the grid, not a legible mark.
        canvas.drawRect(
          cellRect,
          Paint()
            ..color = Colors.white.withValues(alpha: 0.12)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.5,
        );
      }
    }

    // Center pixel crosshair target — the loupe's one load-bearing mark, so
    // (unlike the grid outline above) it gets the guaranteed-contrast
    // ink/onActive pairing: whichever of the two is near-black or near-white
    // in this mode, the other one is always the opposite, so the crosshair
    // stays visible against any sampled colour underneath.
    final centerRect = Rect.fromLTWH(
      halfGrid * cellSize,
      halfGrid * cellSize,
      cellSize,
      cellSize,
    );
    canvas.drawRect(
      centerRect,
      Paint()
        ..color = theme.ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0,
    );
    canvas.drawRect(
      centerRect,
      Paint()
        ..color = theme.onActive
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );
  }

  @override
  bool shouldRepaint(covariant _LoupeGridPainter oldDelegate) =>
      oldDelegate.centerPixel.x != centerPixel.x ||
      oldDelegate.centerPixel.y != centerPixel.y ||
      oldDelegate.theme != theme;
}
