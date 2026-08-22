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
import '../utils/image_eviction.dart';
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
  final double opacity;
  final Color? textBackgroundColor;
  final Color? fillColor;
  final double zoomScale;
  final ValueChanged<double>? onZoomScaleChanged;
  final int imageRevision;

  /// Bumped by every undo and redo.
  ///
  /// Undo rewrites the annotation list from a snapshot, but the selection
  /// chrome, the marquee and any floating cut live in this canvas and nothing
  /// else can reach them — so they stayed painted over the restored state, and
  /// the box the user had just been dragging sat there looking like the edit
  /// had not been undone at all.
  final int historyRevision;
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
    this.opacity = 1.0,
    this.zoomScale = 1.0,
    this.onZoomScaleChanged,
    this.imageRevision = 0,
    this.historyRevision = 0,
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

/// Tools whose mark is a *stroke* rather than an area.
///
/// Their size and their thickness are the same property, so resizing one has to
/// scale both — dragging a 2px line out to twice the length and leaving it 2px
/// thick is not what "make it bigger" means. They also scale uniformly, which
/// is what stops a vertical drag on a near-horizontal arrow from reading as a
/// rotation: the bounding box of such an arrow is only a pixel or two tall, so
/// per-axis scaling turned any vertical movement into a huge change of angle.
/// Stroke tools whose weight a resize must leave alone.
///
/// The pen keeps its thickness slider, and that stays the only way to change a
/// stroke's weight: dragging a squiggle bigger should make it bigger, not
/// heavier. Resizing one of these scales it uniformly and touches nothing else.
const _fixedWeightStrokeTools = {CanvasTool.pen};

/// Stroke tools whose weight rides along with their length.
///
/// An arrow's head is sized from its weight, so lengthening the shaft alone —
/// what the plain along/across split does — left the head behind and the
/// arrow lost its proportions. For these, a drag *along* the mark scales
/// length and weight by one factor, about the opposite corner, so a longer
/// arrow is the same arrow, bigger. A drag *across* it still thickens at the
/// pointer exactly as it does for a line: a pure diagonal-ratio scale was
/// tried first and a vertical pull on a wide flat arrow moved its diagonal by
/// about one percent, so the handle simply did not follow.
const _proportionalStrokeTools = {CanvasTool.arrow};

const _strokeTools = {
  CanvasTool.pen,
  CanvasTool.line,
  CanvasTool.arrow,
  CanvasTool.highlight,
  CanvasTool.ruler,
};

/// The stroke-width range the properties slider offers. Resizing a mark that
/// still has a slider stays inside it, so the slider can always take over
/// afterwards.
const double _minStrokeWidth = 1.0;
const double _maxStrokeWidth = 30.0;

/// The ceiling for marks in [dragSizedStrokeTools], whose thickness is set by
/// dragging alone. No slider has to be able to reach these values, so the only
/// job of this number is to stop a runaway drag — 30 was simply the slider's
/// limit, and it made a dragged line stop growing well before it looked thick
/// on a large capture.
const double _maxDragStrokeWidth = 240.0;


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

  /// Marks the zoom viewport so pointer positions can be resolved against it.
  final GlobalKey _viewportKey = GlobalKey();

  /// True while a space-held drag is moving the viewport rather than drawing.
  bool _isPanningView = false;

  static const double _minZoom = 0.2;
  static const double _maxZoom = 4.0;

  /// Decoded source pixels, used to render blur/pixelate regions on screen with
  /// exactly the same code path the exporter uses.
  ui.Image? _baseImage;
  img.Image? _cachedSourceImage;
  int _baseImageToken = 0;

  /// When the parent was last told a write could not be placed. See
  /// [_reportUnplaceableEdit].
  DateTime? _lastUnplaceableReport;

  /// Set just before notifying the parent about a bitmap this canvas rewrote
  /// itself (flood fill, floating-selection cut/move/delete). The parent
  /// answers with an `imageRevision` bump, and `didUpdateWidget` consumes this
  /// flag to skip re-decoding a bitmap that was already reloaded here.
  bool _suppressNextRevisionReload = false;

  // Selection / transform state
  String? _selectedAnnotationId;
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

  /// True while [_activeCropRect] is still the untouched default the crop tool
  /// installs (the whole image), rather than a box the user has drawn.
  ///
  /// The default covers the entire image, so *every* press that lands on the
  /// picture also lands inside the crop box — and the crop box's hit test
  /// reads an interior press as "move me". The first drag after picking the
  /// crop tool therefore slid the whole-image box off to one side instead of
  /// drawing a region, and applying it kept only the part still over the
  /// picture: the "it crops about half the image" bug. While pristine, an
  /// interior drag starts a fresh box instead; once the user owns the box,
  /// dragging its body moves it as before. Edge and corner handles are hit
  /// tested first either way, so the drag-outward canvas expansion still
  /// works straight from the default.
  bool _cropRectIsPristine = false;
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
  /// Trackpad pan/zoom gesture state. `PointerPanZoomUpdateEvent` reports
  /// cumulative values, so each frame's increment is the difference from the
  /// last one.
  double _trackpadPanZoomScale = 1.0;
  Offset? _trackpadPanZoomOrigin;
  Offset _trackpadPanLast = Offset.zero;

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
      // Post-frame: the viewport has no size until it has been laid out, and
      // the focal point is measured against it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _zoomToCentre(widget.zoomScale);
      });
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

    // A different capture invalidates everything this canvas holds about the
    // one that just went away. Run before the reload below, which is what
    // replaces `_cachedSourceImage` and `_baseImage` with the new bitmap.
    if (oldWidget.imagePath != widget.imagePath) {
      _discardStateForPreviousCapture(oldWidget.imagePath);
    }

    if (oldWidget.imagePath != widget.imagePath ||
        oldWidget.imageRevision != widget.imageRevision) {
      _checkFileExists();
      // A revision bump the canvas itself caused (flood fill, cut/move/delete)
      // has already reloaded the bitmap before notifying the parent — decoding
      // it a second time here would only burn CPU on the exact same bytes.
      final isSelfEdit =
          _suppressNextRevisionReload && oldWidget.imagePath == widget.imagePath;
      _suppressNextRevisionReload = false;
      if (!isSelfEdit) _loadBaseImage();
    }

    // Guarded on the live scale, not on a gesture flag: this same callback is
    // what `_notifyZoom` triggers, so comparing against the controller is what
    // stops a pointer zoom from being re-applied centred on the way back.
    if (oldWidget.zoomScale != widget.zoomScale &&
        (_transformationController.value.getMaxScaleOnAxis() - widget.zoomScale).abs() >
            0.001) {
      _zoomToCentre(widget.zoomScale);
    }

    if (oldWidget.historyRevision != widget.historyRevision) {
      _clearTransientMarks();
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
        _cropRectIsPristine = false;
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

  }

  /// Drops every piece of canvas state that describes the capture the editor
  /// has just switched away from.
  ///
  /// All of it is keyed to one bitmap, and none of it used to be cleared: only
  /// a *tool* change reset any of it, so switching captures with the same tool
  /// still selected carried the previous capture's state onto the new one.
  /// Three of those leaks were destructive rather than cosmetic:
  ///
  /// * A floating cut is already erased from the previous capture's file and
  ///   lives only in `_cutSelectionImage`. Left in place, the next tool change
  ///   pasted those pixels into the **newly selected** capture's file and the
  ///   original capture kept the hole. Committed here against
  ///   [previousPath] instead, which is what switching away should mean.
  /// * An open inline text editor committed its text onto the new capture's
  ///   annotation list — the parent had already swapped it.
  /// * The crop box stayed at the old image's rectangle, so applying it cropped
  ///   the new capture through the previous one's geometry (and, at a different
  ///   aspect ratio, through its letterbox).
  void _discardStateForPreviousCapture(String? previousPath) {
    if (_hasExtractedSelection) {
      // Fire-and-forget, like the tool-change path: the paste is a file write
      // and this runs inside `didUpdateWidget`. `_imageRect` is still the old
      // capture's here, because the reload that replaces `_baseImage` has not
      // run yet — capture it now rather than letting the async body read a
      // rect that by then describes the new bitmap.
      _commitFloatingSelection(toPath: previousPath, throughImageRect: _imageRect);
    } else {
      _floatingSelectionUiImage?.dispose();
      _floatingSelectionUiImage = null;
      _cutSelectionImage = null;
      _floatingSelectionRect = null;
      _floatingSelectionOriginRect = null;
      _hasExtractedSelection = false;
    }
    _selectionMarquee = null;
    _ocrRegion = null;

    // The typed text belongs to a capture that is no longer on screen and
    // cannot be committed to it any more, so it is dropped rather than landing
    // on the wrong one.
    _inlineTextPos = null;
    _editingAnnotationId = null;
    _inlineTextController.clear();

    _activeCropRect = null;
    _cropRectIsPristine = false;
    _isDraggingCrop = false;
    _currentCropHandle = _CropHandle.none;
    _cropOrigin = null;

    _isDraggingSelection = false;
    _currentSelectionHandle = _CropHandle.none;
    _selectionGestureOriginRect = null;

    _isDraggingAnnotation = false;
    _isResizingAnnotation = false;
    _isRotatingAnnotation = false;
    _currentAnnHandle = _AnnHandle.none;
    _gestureOrigin = null;
    _currentAnnotation = null;
    _drawStart = null;

    // The loupe is showing a pixel colour read out of the old bitmap.
    _hoverPos = null;
    _hoverColor = null;
    _hoverPixelPos = null;

    final hadSelection = _selectedAnnotationId != null;
    _selectedAnnotationId = null;
    if (hadSelection && widget.onSelectAnnotation != null) {
      // The parent's `_selectedAnnotationId` still points at an annotation
      // belonging to the previous capture; post-frame because this runs during
      // the parent's own build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onSelectAnnotation!(null);
      });
    }

    // Deliberately no `_ensureCropRectInitialized()` here: `_baseImage` still
    // holds the *previous* capture's bitmap at this point (the reload below is
    // async), so seeding a default now would hand the new capture the old
    // image's rectangle — the very carry-over this method exists to stop.
    // `_loadBaseImage` seeds it once the new decode lands.
  }

  /// Drops everything this canvas draws that is not in the annotation list.
  ///
  /// Used after an undo or redo: the restored list is authoritative, and any
  /// selection, marquee or in-flight cut describes the state that was just
  /// thrown away. A floating cut is *discarded* rather than committed — undo
  /// has already put those pixels back into the bitmap, so pasting the copy
  /// held in memory would stamp them in a second time.
  void _clearTransientMarks() {
    _floatingSelectionUiImage?.dispose();
    _floatingSelectionUiImage = null;
    _cutSelectionImage = null;
    _floatingSelectionRect = null;
    _floatingSelectionOriginRect = null;
    _hasExtractedSelection = false;
    _selectionMarquee = null;
    _ocrRegion = null;

    _currentAnnotation = null;
    _drawStart = null;
    _gestureOrigin = null;
    _currentAnnHandle = _AnnHandle.none;
    _isDraggingAnnotation = false;
    _isResizingAnnotation = false;
    _isRotatingAnnotation = false;
    _isDraggingSelection = false;
    _currentSelectionHandle = _CropHandle.none;
    _selectionGestureOriginRect = null;
    _isPanningView = false;

    final hadSelection = _selectedAnnotationId != null;
    _selectedAnnotationId = null;
    if (hadSelection && widget.onSelectAnnotation != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onSelectAnnotation!(null);
      });
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
      // Decoded off the UI isolate: a pure-Dart PNG decode of a Retina-sized
      // capture takes long enough to visibly freeze the interface, and this
      // runs on every capture switch and every bitmap rewrite.
      final decodedImg = await compute(img.decodeImage, bytes);
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
      // The crop tool's default box needs the decoded size; if the user picked
      // crop before this landed, `_ensureCropRectInitialized` bailed out and
      // this is the only other moment it can succeed.
      _ensureCropRectInitialized();
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

  /// Size of the zoom viewport — the area the transform is applied *within*,
  /// which is what pointer positions from the surrounding [Listener] are
  /// relative to. Distinct from [_canvasSize], which is the untransformed child
  /// inside it.
  Size get _viewportSize {
    final box = _viewportKey.currentContext?.findRenderObject();
    if (box is RenderBox && box.hasSize) return box.size;
    return Size.zero;
  }

  /// Keeps the content from being panned out of sight.
  ///
  /// On an axis where the scaled content is smaller than the viewport there is
  /// nothing to pan, so it is pinned centred; on an axis where it is larger,
  /// translation is clamped to its own edges. Without this, `boundaryMargin:
  /// infinity` lets a flick throw the capture off screen with no way back.
  Matrix4 _constrain(Matrix4 matrix) {
    final viewport = _viewportSize;
    if (viewport.isEmpty) return matrix;
    final scale = matrix.getMaxScaleOnAxis();
    final storage = matrix.storage;

    double axis(double translation, double viewportExtent) {
      final contentExtent = viewportExtent * scale;
      if (contentExtent <= viewportExtent) return (viewportExtent - contentExtent) / 2;
      return translation.clamp(viewportExtent - contentExtent, 0.0);
    }

    storage[12] = axis(storage[12], viewport.width);
    storage[13] = axis(storage[13], viewport.height);
    return matrix;
  }

  void _setTransform(Matrix4 matrix) {
    _transformationController.value = _constrain(matrix);
  }

  /// Scales to [targetScale] while holding [focalPoint] (viewport coordinates)
  /// still under the pointer.
  ///
  /// Composed onto the *current* matrix rather than rebuilt from identity. The
  /// previous implementation constructed a fresh centre-anchored matrix on
  /// every step, which threw away the translation — so any pan was undone by
  /// the next zoom, and zooming always dragged the view back to the middle of
  /// the image instead of magnifying what the cursor was over.
  void _zoomAt(double targetScale, Offset focalPoint) {
    final matrix = _transformationController.value;
    final current = matrix.getMaxScaleOnAxis();
    final clamped = targetScale.clamp(_minZoom, _maxZoom);
    final factor = clamped / current;
    if ((factor - 1.0).abs() < 1e-6) return;

    final zoom = Matrix4.identity()
      ..translateByDouble(focalPoint.dx, focalPoint.dy, 0, 1)
      // Z scales with X and Y, which matters only because `getMaxScaleOnAxis`
      // reports the largest column norm of all three: leaving Z at 1 makes it
      // report 1.0 for every scale below 1.0, so zooming out read back as "no
      // change" and stuck at 100%. Z has no effect on a 2D transform otherwise.
      ..scaleByDouble(factor, factor, factor, 1)
      ..translateByDouble(-focalPoint.dx, -focalPoint.dy, 0, 1);
    _setTransform(zoom.multiplied(matrix));
    _notifyZoom();
  }

  /// Zooms about the middle of the viewport — for the header's stepper, which
  /// has no pointer to anchor to.
  void _zoomToCentre(double targetScale) {
    final viewport = _viewportSize;
    if (viewport.isEmpty) return;
    _zoomAt(targetScale, viewport.center(Offset.zero));
  }

  void _panBy(Offset delta) {
    final matrix = _transformationController.value;
    if (matrix.getMaxScaleOnAxis() <= 1.0 + 1e-6) return;
    final pan = Matrix4.identity()..translateByDouble(delta.dx, delta.dy, 0, 1);
    _setTransform(pan.multiplied(matrix));
  }

  void _notifyZoom() {
    final scale = _transformationController.value.getMaxScaleOnAxis();
    if ((scale - widget.zoomScale).abs() > 0.001) {
      widget.onZoomScaleChanged?.call(scale);
    }
  }

  /// Mouse wheel and trackpad two-finger scroll.
  ///
  /// Plain scroll pans and Cmd/Ctrl+scroll zooms, which is what every image
  /// editor this one is measured against does — including Snagit. Scroll used
  /// to zoom unconditionally, which left no way to pan at all.
  void _handlePointerSignal(PointerSignalEvent signal) {
    if (signal is! PointerScrollEvent) return;
    if (_isZoomModifierDown) {
      _zoomByFactor(_zoomFactorForDelta(signal.scrollDelta.dy), signal.localPosition);
      return;
    }
    var delta = signal.scrollDelta;
    // A notched wheel only reports dy. Shift swaps it onto the other axis, the
    // long-standing convention for horizontal scrolling without a tilt wheel;
    // a trackpad already reports both and needs no help.
    if (delta.dx == 0 && _isShiftDown) delta = Offset(delta.dy, 0);
    _panBy(-delta);
  }

  /// True when the view is zoomed in far enough that there is somewhere to pan.
  bool get _canPanView =>
      _transformationController.value.getMaxScaleOnAxis() > 1.0 + 1e-6;

  bool get _isZoomModifierDown {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    return keys.contains(LogicalKeyboardKey.metaLeft) ||
        keys.contains(LogicalKeyboardKey.metaRight) ||
        keys.contains(LogicalKeyboardKey.controlLeft) ||
        keys.contains(LogicalKeyboardKey.controlRight);
  }

  /// True while the view-pan modifier is held, so a drag moves the viewport
  /// instead of drawing. Space is the near-universal convention for this.
  bool get _isPanModifierDown =>
      HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.space);

  /// Exponential, and proportional to how far the wheel actually moved.
  ///
  /// The old step was a flat ±0.05 per event regardless of the gesture: a 25%
  /// jump at 0.2x and a 1.25% nudge at 4x, which is what made zooming feel
  /// coarse at the bottom and unresponsive at the top. Scaling multiplicatively
  /// makes every notch the same *perceived* step, and honouring the delta lets
  /// a trackpad resolve much finer than a notched wheel.
  double _zoomFactorForDelta(double delta) => math.exp(-delta * 0.0035);

  void _zoomByFactor(double factor, Offset focalPoint) {
    final current = _transformationController.value.getMaxScaleOnAxis();
    _zoomAt(current * factor, focalPoint);
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
      //
      // `_imageRect` falls back to the whole canvas while the bitmap is still
      // decoding, which is exactly the letterbox-inclusive box this is meant
      // to avoid — pick the crop tool quickly enough and applying it padded
      // the capture with transparent bars instead of cropping it. Wait for the
      // decode instead; `_loadBaseImage`'s setState reruns this through build.
      if (_baseImage == null) return;
      final rect = _imageRect;
      if (rect.width > 0 && rect.height > 0) {
        setState(() {
          _activeCropRect = rect;
          _cropRectIsPristine = true;
        });
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
    _cropRectIsPristine = false;

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

  /// Resizes a stroke by moving its bounding box exactly the way the shape tool
  /// does — the grabbed corner follows the pointer — and then reading the two
  /// things a stroke has out of the new box: its length along its own axis, and
  /// its weight across it.
  ///
  /// Working from box extents rather than from the raw drag is what makes the
  /// two axes fall out cleanly. A purely sideways drag on a horizontal line
  /// changes the box width and nothing else, so the length changes and the
  /// weight is untouched — exactly, with no threshold needed to suppress
  /// crosstalk. A purely vertical drag changes only the height, so only the
  /// weight moves.
  ///
  /// The angle is fixed by construction: the mark is scaled along its existing
  /// direction rather than stretched to fill the box, which is what used to
  /// swing a near-horizontal arrow around on the smallest vertical movement.
  Annotation _resizeStroke(Annotation origin, _AnnHandle handle, Offset totalDelta) {
    // `boundingRect`, not `selectionRect`: the handle sits a constant inset
    // outside, and a constant cancels out of every delta below.
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
      case _AnnHandle.topRight:
        right += totalDelta.dx;
        top += totalDelta.dy;
      case _AnnHandle.bottomLeft:
        left += totalDelta.dx;
        bottom += totalDelta.dy;
      case _AnnHandle.bottomRight:
        right += totalDelta.dx;
        bottom += totalDelta.dy;
      default:
        return origin;
    }
    final grown = Rect.fromLTRB(
      math.min(left, right),
      math.min(top, bottom),
      math.max(left, right),
      math.max(top, bottom),
    );

    // Which side of the box is the mark's length, and which is its weight.
    // Snapped to whichever screen axis the stroke is closer to, rather than
    // blended across both: a line drawn two pixels off horizontal is horizontal
    // as far as anyone using it is concerned, and blending would leak a slice
    // of every sideways drag into its thickness.
    final axis = _strokeAxis(origin, bounds);
    final runsHorizontally = axis.dx.abs() >= axis.dy.abs();
    double along(Rect r) => runsHorizontally ? r.width : r.height;
    double across(Rect r) => runsHorizontally ? r.height : r.width;

    final fixedWeight = _fixedWeightStrokeTools.contains(origin.tool);
    final proportional = _proportionalStrokeTools.contains(origin.tool);
    final ceiling = dragSizedStrokeTools.contains(origin.tool)
        ? _maxDragStrokeWidth
        : _maxStrokeWidth;

    double diagonal(Rect r) => math.sqrt(r.width * r.width + r.height * r.height);
    final wasDiagonal = diagonal(bounds);
    final uniformFactor =
        wasDiagonal < 1.0 ? 1.0 : (diagonal(grown) / wasDiagonal).clamp(0.05, 20.0);

    // Length from the change in the along-extent, one pixel for one pixel (see
    // the note below). Computed up front because a proportional mark's weight
    // is derived from it.
    final oldRun = math.max(1.0, along(bounds) - origin.strokeWidth);
    final newRun = math.max(1.0, oldRun + along(grown) - along(bounds));
    final alongFactor = (newRun / oldRun).clamp(0.05, 20.0);
    // The box change is what the pointer asked for; the stroke weight that
    // produces it is that divided by how fast this mark grows per unit of
    // weight. One for a plain stroke, eight for a ruler — whose caps reach
    // 3.5x the weight on each side of its line, so treating the two as
    // interchangeable made a ruler explode under the smallest drag.
    final perUnit = AnnotationRenderer.acrossExtentPerStrokeWidth(origin.tool);
    // A proportional mark's weight starts from the along-scaled value, then
    // takes the across drag on top — so a sideways pull thickens it just as it
    // thickens a line, and a lengthwise pull keeps it in proportion.
    final baseWeight = proportional ? origin.strokeWidth * alongFactor : origin.strokeWidth;
    final width = fixedWeight
        ? origin.strokeWidth
        : (baseWeight + (across(grown) - across(bounds)) / perUnit)
            .clamp(_minStrokeWidth, ceiling);

    // Length follows the *change* in the box's along-extent, one pixel for one
    // pixel, so the far end tracks the pointer exactly as a shape's corner
    // does. Deriving it from the new extent instead would couple the two axes
    // back together: the bounds grow by the stroke weight on every side, so a
    // purely downward drag would have thickened the mark and shortened it by
    // the same amount in one gesture.
    // A fixed-weight mark reads nothing out of the across-axis on its own, so
    // the whole box drives a uniform scale: every corner drag makes it bigger
    // or smaller in proportion, whichever way it is pulled. Everything else
    // takes its length from the along-axis alone.
    final factor = fixedWeight ? uniformFactor : alongFactor;

    // A stroke straddles its own centre line, so growing the weight alone would
    // push it out in *both* directions — hold the bottom handle and the top
    // edge climbs away from you too. Offsetting the mark by half the growth,
    // away from the edge being held, pins that edge exactly as dragging a
    // shape's bottom corner leaves its top where it was.
    final acrossAxis = runsHorizontally ? const Offset(0, 1) : const Offset(1, 0);
    final growsPositive = runsHorizontally
        ? handle == _AnnHandle.bottomLeft || handle == _AnnHandle.bottomRight
        : handle == _AnnHandle.topRight || handle == _AnnHandle.bottomRight;
    // Offset by half the *achieved* growth in drawn height, not half the change
    // in stroke weight: for a ruler those differ by a factor of eight, and
    // using the weight left the top edge climbing away while the bottom was
    // held. Reading it back from the clamped width also keeps the pin honest
    // once the drag hits the ceiling.
    // No weight change means no edge to pin, so nothing is offset.
    // Only the across-drag's share of the growth is pinned: the part a
    // proportional mark gained from its along-scale is already anchored at
    // the opposite corner by the scale itself.
    final grownAcross = (width - baseWeight) * perUnit;
    final shift = fixedWeight
        ? Offset.zero
        : acrossAxis * (grownAcross / 2) * (growsPositive ? 1.0 : -1.0);

    // Scale about whichever end is nearest the corner being anchored, so that
    // end stays genuinely put rather than creeping as the mark grows. A
    // proportional mark scales about the box corner itself: its whole outline
    // — weight and head included — is linear in the scale, so the far corner
    // of the box is exactly what stays put, as it does for a shape.
    final anchor = proportional
        ? _oppositeCorner(bounds, handle)
        : _resizeAnchor(origin, bounds, handle);
    Offset scaled(Offset p) => anchor + (p - anchor) * factor + shift;

    return origin.copyWith(
      strokeWidth: width,
      points: origin.points.isEmpty ? null : origin.points.map(scaled).toList(),
      startPoint: origin.startPoint == null ? null : scaled(origin.startPoint!),
      endPoint: origin.endPoint == null ? null : scaled(origin.endPoint!),
      // The curve control point rides along, or a curved arrow straightens out.
      controlPoint:
          origin.controlPoint == null ? null : scaled(origin.controlPoint!),
    );
  }

  Offset _oppositeCorner(Rect bounds, _AnnHandle handle) => switch (handle) {
        _AnnHandle.topLeft => bounds.bottomRight,
        _AnnHandle.topRight => bounds.bottomLeft,
        _AnnHandle.bottomLeft => bounds.topRight,
        _ => bounds.topLeft,
      };

  /// The point a resize scales about: the corner of [bounds] opposite [handle]
  /// for a freehand mark, or — for a two-point mark — whichever of its ends is
  /// nearest that corner, so that end does not drift.
  Offset _resizeAnchor(Annotation origin, Rect bounds, _AnnHandle handle) {
    final corner = switch (handle) {
      _AnnHandle.topLeft => bounds.bottomRight,
      _AnnHandle.topRight => bounds.bottomLeft,
      _AnnHandle.bottomLeft => bounds.topRight,
      _ => bounds.topLeft,
    };
    final start = origin.startPoint;
    final end = origin.endPoint;
    if (start == null || end == null) return corner;
    return (start - corner).distanceSquared <= (end - corner).distanceSquared
        ? start
        : end;
  }

  /// The unit vector a stroke runs along.
  ///
  /// Two-point marks have a real direction. A freehand squiggle does not, so it
  /// falls back to whichever way its bounding box is longer — the axis a user
  /// would call its length.
  Offset _strokeAxis(Annotation origin, Rect bounds) {
    final start = origin.startPoint;
    final end = origin.endPoint;
    if (start != null && end != null) {
      final span = end - start;
      if (span.distance > 1.0) return span / span.distance;
    }
    return bounds.width >= bounds.height ? const Offset(1, 0) : const Offset(0, 1);
  }

  Annotation _resizeAnnotation(Annotation origin, _AnnHandle handle, Offset totalDelta) {
    if (origin.tool == CanvasTool.text || origin.tool == CanvasTool.stepMarker) {
      // Point-anchored items scale by their type size rather than by bounds.
      final grow = (handle == _AnnHandle.bottomRight || handle == _AnnHandle.topRight)
          ? totalDelta.dx
          : -totalDelta.dx;
      return origin.copyWith(fontSize: (origin.fontSize + grow * 0.4).clamp(8.0, 120.0));
    }

    if (_strokeTools.contains(origin.tool)) {
      return _resizeStroke(origin, handle, totalDelta);
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
  void onActiveCropRectChanged(Rect? rect) => setState(() {
        _activeCropRect = rect;
        _cropRectIsPristine = false;
      });

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

    // Space held: drag moves the viewport rather than drawing on it. Checked
    // before every tool branch so it works from whichever tool is selected,
    // and it is the only way to reach an off-centre area with a mouse that has
    // no scroll wheel.
    if (_isPanModifierDown) {
      _isPanningView = true;
      return;
    }

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
        // An interior press on the untouched default box draws a new region
        // rather than dragging the default around — see `_cropRectIsPristine`.
        // Handles are unaffected, so expanding outward from the default still
        // works on the first gesture.
        final isPristineBodyDrag = handle == _CropHandle.move && _cropRectIsPristine;
        if (handle != _CropHandle.none && !isPristineBodyDrag) {
          setState(() {
            _isDraggingCrop = true;
            _currentCropHandle = handle;
            _cropOrigin = _activeCropRect;
            _cropRectIsPristine = false;
          });
          return;
        }
      }
      setState(() {
        _selectedAnnotationId = null;
        _drawStart = pos;
        _activeCropRect = Rect.fromPoints(pos, pos);
        _cropRectIsPristine = false;
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

    // Transform the current selection when one of its handles is grabbed.
    //
    // Ahead of every per-tool branch, because the Select tool's own workflow
    // below returns unconditionally: with Select active — the tool anyone would
    // reach for to resize something — the handles were unreachable, and
    // grabbing a corner fell through to `hitTestAnnotation`'s bounding-box
    // fallback and *moved* the annotation instead of resizing it.
    //
    // A live floating selection outranks it: those two selections are mutually
    // exclusive in practice, and the marquee's own handles share this space.
    final selected = _floatingSelectionRect == null ? _selectedAnnotation : null;
    if (selected != null) {
      final handle = _hitTestAnnotationHandles(pos, selected);
      if (handle != _AnnHandle.none && handle != _AnnHandle.body) {
        _pushHistoryCheckpoint();
        setState(() {
          _gestureOrigin = selected;
          _isDraggingAnnotation = false;
          _isRotatingAnnotation = handle == _AnnHandle.rotate;
          _isResizingAnnotation =
              !_isRotatingAnnotation && handle != _AnnHandle.curve;
          _currentAnnHandle = handle;
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

    if (_isPanningView) {
      // `details.delta` is in the child's coordinate space, which is already
      // divided by the zoom; the viewport translation wants viewport pixels.
      _panBy(details.delta * _transformationController.value.getMaxScaleOnAxis());
      return;
    }

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
      setState(() {
        _activeCropRect = Rect.fromPoints(_drawStart!, end);
        _cropRectIsPristine = false;
      });
      return;
    }

    // Nothing canvas-owned claimed the gesture: it is a tool drawing.
    if (_currentAnnotation == null || _drawStart == null) return;
    _toolHandler.onPanUpdate(details, pos);
  }

  void _onPanEnd(DragEndDetails details) {
    if (_isPanningView) {
      _isPanningView = false;
      return;
    }
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
        // Back to the default box, so the next drag draws rather than moves.
        setState(() {
          _activeCropRect = _imageRect;
          _cropRectIsPristine = true;
        });
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
        decoded = await compute(img.decodeImage, await File(path).readAsBytes());
        if (!mounted) return;
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
  }

  Future<ui.Image?> _imageToUiImage(img.Image image) async {
    try {
      final pngBytes = await compute(img.encodePng, image);
      final codec = await ui.instantiateImageCodec(Uint8List.fromList(pngBytes));
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
        decoded = await compute(img.decodeImage, await File(path).readAsBytes());
        if (!mounted) return;
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

      final cutBytes = await compute(img.encodePng, decoded);
      if (!mounted || widget.imagePath != path) return;
      await File(path).writeAsBytes(Uint8List.fromList(cutBytes));
      // Targeted eviction only: the gallery thumbnail for this path must
      // refresh, but a global imageCache.clear() would force every other
      // thumbnail to re-decode too — the visible "everything flashes" bug.
      await evictImageFileFromCaches(path);

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
      if (mounted && widget.onImageBytesChanged != null) {
        _suppressNextRevisionReload = true;
        widget.onImageBytesChanged!.call();
      }
    } catch (e) {
      debugPrint('Error extracting floating selection: $e');
    }
  }

  /// Pastes the floating cut back into the bitmap and clears the selection.
  ///
  /// [toPath] and [throughImageRect] exist for the capture-switch path, which
  /// has to write into the capture the region was cut *out* of — by then
  /// `widget.imagePath` and `_imageRect` already describe the newly selected
  /// capture, and using them would stamp one capture's pixels into another
  /// capture's file. Every other caller wants the live values and passes
  /// neither.
  Future<void> _commitFloatingSelection({
    String? toPath,
    Rect? throughImageRect,
  }) async {
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

    final isForeignTarget = toPath != null && toPath != widget.imagePath;
    final path = toPath ?? widget.imagePath;
    final currentRect = _floatingSelectionRect!;
    final cutImg = _cutSelectionImage!;
    var wroteBitmap = false;

    try {
      // `_cachedSourceImage` tracks whatever the canvas is showing now, which
      // is the wrong bitmap once the target is a capture we have switched
      // away from — decode that file fresh instead, and leave the cache alone.
      img.Image? decoded = isForeignTarget ? null : _cachedSourceImage;
      if (decoded == null && path != null && File(path).existsSync()) {
        decoded = await compute(img.decodeImage, await File(path).readAsBytes());
        if (!isForeignTarget) _cachedSourceImage = decoded;
      }
      if (decoded != null && path != null) {
        final imageRect = throughImageRect ?? _imageRect;
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

        final pasted = await compute(img.encodePng, decoded);
        await File(path).writeAsBytes(Uint8List.fromList(pasted));
        await evictImageFileFromCaches(path);
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
      if (wroteBitmap && mounted && widget.onImageBytesChanged != null) {
        // The suppression only ever applies to a revision bump for the bitmap
        // on screen. Claiming it for a write into a capture we just left would
        // make the *next* legitimate reload of the current capture a no-op.
        _suppressNextRevisionReload = !isForeignTarget;
        widget.onImageBytesChanged!.call();
      }
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
      final pngBytes = Uint8List.fromList(await compute(img.encodePng, _cutSelectionImage!));
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
      final bytes = await File(path).readAsBytes();
      if (!mounted) return;

      img.Image? decoded = _cachedSourceImage;
      if (decoded == null) {
        decoded = await compute(img.decodeImage, bytes);
        if (!mounted) return;
        _cachedSourceImage = decoded;
      }
      if (decoded == null) return;

      final pixelPos = _canvasPointToImagePixel(localPos, decoded.width, decoded.height);
      if (pixelPos == null) return;

      // Snapshot the pre-fill bitmap *before* it is overwritten for undo.
      final beforeFill = widget.onBeforeCanvasFill;
      if (beforeFill != null) await beforeFill();
      if (!mounted) return;

      // The fill itself runs on a worker isolate: it is a per-pixel walk of the
      // whole bitmap, plus a full PNG re-encode. Both on the UI isolate froze
      // the window for seconds on a large capture.
      final filled = await compute(floodFillPng, (
        pngBytes: bytes,
        startX: pixelPos.x,
        startY: pixelPos.y,
        fillArgb: widget.activeColor.toARGB32(),
        tolerancePercent: widget.fillTolerance,
        opacity: widget.opacity,
        isGlobal: widget.isGlobalFill,
      ));
      // Null means nothing matched the click, so there is nothing to write.
      if (filled == null) return;
      // The capture can be switched while the fill runs; writing now would put
      // one capture's pixels into another capture's file.
      if (!mounted || widget.imagePath != path) return;

      await File(path).writeAsBytes(filled);
      await evictImageFileFromCaches(path);

      await _loadBaseImage();
      if (mounted && widget.onPerformCanvasFill != null) {
        _suppressNextRevisionReload = true;
        widget.onPerformCanvasFill!.call(localPos);
      }
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

    // When typing in the inline text editor, do NOT let character keys, navigation keys,
    // or tool shortcut chords bubble up and switch tools or mutate canvas objects.
    if (_inlineTextPos != null || _inlineTextFocusNode.hasFocus) {
      if (key == LogicalKeyboardKey.escape) {
        _commitInlineText();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

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
    setState(() {
      _activeCropRect = null;
      _cropRectIsPristine = false;
    });
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
    // Space held over a zoomed-in view: this drag will pan, so say so before
    // the user commits to it.
    if (_isPanModifierDown && _canPanView) {
      final grab = _isPanningView ? SystemMouseCursors.grabbing : SystemMouseCursors.grab;
      if (_cursor != grab) setState(() => _cursor = grab);
      return;
    }

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
                key: _viewportKey,
                onPointerSignal: _handlePointerSignal,
                // Trackpad pan/zoom arrives as its own event family on desktop,
                // never as a scroll signal, so it needs handling of its own:
                // two-finger drag pans, pinch zooms about the gesture's origin.
                onPointerPanZoomStart: (event) {
                  _trackpadPanZoomScale = 1.0;
                  _trackpadPanZoomOrigin = event.localPosition;
                },
                onPointerPanZoomUpdate: (event) {
                  final origin = _trackpadPanZoomOrigin ?? event.localPosition;
                  if (event.scale != _trackpadPanZoomScale && event.scale > 0) {
                    _zoomByFactor(event.scale / _trackpadPanZoomScale, origin);
                    _trackpadPanZoomScale = event.scale;
                  }
                  final panDelta = event.localPan - _trackpadPanLast;
                  _trackpadPanLast = event.localPan;
                  if (panDelta != Offset.zero) _panBy(panDelta);
                },
                onPointerPanZoomEnd: (_) {
                  _trackpadPanZoomScale = 1.0;
                  _trackpadPanZoomOrigin = null;
                  _trackpadPanLast = Offset.zero;
                },
                child: InteractiveViewer(
                  transformationController: _transformationController,
                  maxScale: _maxZoom,
                  minScale: _minZoom,
                  boundaryMargin: const EdgeInsets.all(double.infinity),
                  // Both disabled: this canvas owns every zoom and pan gesture
                  // itself (see `_handlePointerSignal` and the pan-modifier
                  // branch in `_onPanStart`). Leaving either on would put
                  // InteractiveViewer's own recognisers in the arena against
                  // the drawing tools, and double-apply the trackpad gestures
                  // handled above. What is left of it is the clipped Transform
                  // that follows the controller.
                  panEnabled: false,
                  scaleEnabled: false,
                  clipBehavior: Clip.hardEdge,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: RepaintBoundary(
                      key: widget.repaintBoundaryKey,
                      child: Stack(
                        alignment: Alignment.center,
                        clipBehavior: Clip.none,
                        children: [
                          // Checkerboard directly under the image (revealed under transparent PNG pixels)
                          if (_imageRect.width > 0 && _imageRect.height > 0)
                            Positioned(
                              left: _imageRect.left,
                              top: _imageRect.top,
                              width: _imageRect.width,
                              height: _imageRect.height,
                              child: Container(
                                decoration: BoxDecoration(
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: t.isDark ? 0.35 : 0.08),
                                      blurRadius: 10,
                                      offset: const Offset(0, 3),
                                    ),
                                  ],
                                ),
                                child: ClipRect(
                                  child: CustomPaint(
                                    painter: _SteadyCheckerboardPainter(theme: t),
                                  ),
                                ),
                              ),
                            ),

                          // The already-decoded bitmap, not `Image.file`: a
                          // keyed Image.file remounts on every revision bump
                          // and paints nothing until its new decode lands —
                          // the visible flash on fill/crop/undo. `_baseImage`
                          // swaps atomically inside setState, so the old
                          // frame stays up until the new one is ready.
                          RawImage(
                            image: _baseImage,
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
                                    // Everything except the trackpad's own
                                    // pan/zoom pointer.
                                    //
                                    // `DragGestureRecognizer` treats a
                                    // `PointerPanZoom` sequence as a drag, so a
                                    // two-finger swipe to scroll around a
                                    // zoomed-in capture also drew with whatever
                                    // tool was selected — one stray stroke per
                                    // pan. Those events carry
                                    // `PointerDeviceKind.trackpad`; a click-drag
                                    // on the same trackpad arrives as `mouse`
                                    // and still draws normally.
                                    supportedDevices: const {
                                      PointerDeviceKind.mouse,
                                      PointerDeviceKind.touch,
                                      PointerDeviceKind.stylus,
                                      PointerDeviceKind.invertedStylus,
                                      PointerDeviceKind.unknown,
                                    },
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

                          // OCR region marquee, drawn while the drag is live —
                          // the affordance telling the user exactly what is
                          // about to be OCR'd, so (like the crop and
                          // floating-selection boundaries) it is a primary
                          // interactive affordance over arbitrary screenshot
                          // content, not app-panel chrome. A single
                          // `t.border` hairline is the PANEL token — nowhere
                          // near ink/onActive's near-black/near-white
                          // extremes — and would nearly vanish against the
                          // common case of a light-grey app UI or document
                          // region. Paired ink/onActive instead, same as the
                          // other boundary marks: an outer onActive ring
                          // (inflated 1px) behind an inner ink ring.
                          if (widget.activeTool == CanvasTool.ocr &&
                              _ocrRegion != null) ...[
                            Positioned.fromRect(
                              rect: _ocrRegion!.inflate(1.0),
                              child: IgnorePointer(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    border: Border.all(color: t.onActive, width: 2.2),
                                  ),
                                ),
                              ),
                            ),
                            Positioned.fromRect(
                              rect: _ocrRegion!,
                              child: IgnorePointer(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: t.ink.withValues(alpha: 0.1),
                                    border: Border.all(color: t.ink, width: 1.4),
                                  ),
                                ),
                              ),
                            ),
                          ],

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
      child: Container(
        constraints: const BoxConstraints(maxWidth: 460),
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 36),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: t.border),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: t.isDark ? 0.35 : 0.06),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 14,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Image.asset(
                  'assets/images/app_logo.png',
                  fit: BoxFit.cover,
                  errorBuilder: (ctx, err, stack) => Container(
                    color: t.surfaceRaised,
                    child: Icon(Icons.crop_free_rounded, size: 40, color: t.emphasis),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Welcome to SnipSnap',
              style: TextStyle(
                color: t.ink,
                fontSize: 22,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.3,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Capture any screen area or open an existing image to start annotating, framing, and extracting text.',
              textAlign: TextAlign.center,
              style: TextStyle(color: t.inkMuted, fontSize: 13.5, height: 1.45),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _emptyStatePill(t, Icons.crop_free_rounded, 'Snip Area', 'Cmd+Shift+1'),
                const SizedBox(width: 8),
                _emptyStatePill(t, Icons.file_open_rounded, 'Open Image', 'Cmd+O'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyStatePill(SnipTheme t, IconData icon, String label, String shortcut) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: t.surfaceRaised,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.border, width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: t.emphasis),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: t.ink,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            shortcut,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w500,
              color: t.inkFaint,
            ),
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
                  setState(() {
                    _activeCropRect = null;
                    _cropRectIsPristine = false;
                  });
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
    // The frame's own background is `t.surface` (a known token, high
    // contrast against `t.ink` by construction) UNLESS `showBg` is true, in
    // which case it is the user's own arbitrary `textBackgroundColor` —
    // annotation data, not chrome. A fixed `t.ink` border would repeat Task
    // 4's swatch-ring bug (a ring vanishing against a near-black or
    // near-white real colour) the moment someone picks a dark text
    // background in light mode or vice versa, so the border contrasts
    // against whichever background is actually painted.
    final frameBg = showBg ? (widget.textBackgroundColor ?? Colors.black87) : t.surface;
    // frameBg can be translucent (AppDefaults.textBackgroundColor ships at
    // alpha 0xCC, and the user can pick any alpha via the colour dialog).
    // The true backdrop behind this floating editor is arbitrary canvas
    // content, which ringOn can't know statically — t.surface is the same
    // documented approximation Task 5 used elsewhere for chrome sitting on
    // unknowable image content, and is exact whenever showBg is false.

    return Positioned(
      left: math.max(10, pos.dx - 8),
      top: math.max(10, pos.dy - 6),
      child: Material(
        color: Colors.transparent,
        child: Container(
          constraints: const BoxConstraints(minWidth: 120, maxWidth: 450),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: frameBg,
            borderRadius: BorderRadius.circular(widget.borderRadius.clamp(4.0, 16.0)),
            border: Border.all(color: t.ringOn(frameBg, backdrop: t.surface), width: 2.0),
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
            // Circular 9x9 Zoom Grid Loupe. The brief names "the loupe
            // frame" itself as an example of chrome that sits on unknown
            // image pixels near the cursor, so — like the crop and
            // floating-selection boundaries, and the OCR marquee — the
            // outer ring is a paired onActive/ink halo rather than a single
            // `ink` ring that could blend into a similarly-toned screenshot
            // region right where the user is about to sample a colour.
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: t.onActive, width: 2.2),
              ),
              child: Center(
                child: Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: t.ink, width: 1.6),
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
                          // A sampled pixel from a screenshot with an alpha
                          // channel (e.g. a cropped/erased region) can be
                          // translucent — this badge paints it on
                          // t.surfaceRaised, so that's the real backdrop.
                          border: Border.all(
                            color: t.ringOn(color, backdrop: t.surfaceRaised),
                            width: 0.8,
                          ),
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
      // Checkerboard everywhere the crop extends beyond the bitmap. The
      // overlap is only subtracted when it exists — a crop dragged entirely
      // off the image produces a negative-size intersection, and adding that
      // degenerate rect to the even-odd path corrupts the whole preview.
      final overlap = imageRect.intersect(cropRect);
      final expandedPath = Path()..addRect(cropRect);
      if (overlap.width > 0 && overlap.height > 0) {
        expandedPath.addRect(overlap);
      }
      expandedPath.fillType = PathFillType.evenOdd;

      canvas.save();
      canvas.clipPath(expandedPath);
      _drawCheckerboardGrid(canvas, cropRect, theme);
      canvas.restore();
    }

    // 3. Draw original image boundary if cropRect is adjusted — this is the
    // only indicator of where the real image ends and the transparent
    // expansion padding begins, so it is load-bearing, not decorative. It
    // draws whenever cropRect != imageRect, which in practice is mostly the
    // *expansion* case (the crop action bar even labels it "Apply
    // Expansion") — meaning this line typically sits on the checkerboard
    // (`theme.surface`/`theme.surfaceRaised`, near-white in light mode),
    // not on the scrim. A fixed light stroke tuned for the scrim would
    // nearly disappear there. Paired ink/onActive, like the crop border
    // below, so it stays visible against both the checkerboard and the
    // scrim it may also partly cross when only some edges are expanded.
    if (cropRect != imageRect && imageRect.width > 0 && imageRect.height > 0) {
      canvas.drawRect(
        imageRect,
        Paint()
          ..color = theme.onActive
          ..strokeWidth = 2.2
          ..style = PaintingStyle.stroke,
      );
      canvas.drawRect(
        imageRect,
        Paint()
          ..color = theme.ink
          ..strokeWidth = 1.0
          ..style = PaintingStyle.stroke,
      );
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

    // 5. Rule-of-thirds guides — a purely decorative composition aid, not an
    // affordance the user must be able to see and act on (unlike the crop
    // border, handles, and the boundary stroke above, all of which are now
    // paired). Kept as a fixed, low-alpha literal on purpose: reviewed and
    // accepted as low-stakes.
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
  bool shouldRepaint(covariant _FloatingSelectionPainter oldDelegate) =>
      oldDelegate.marqueeRect != marqueeRect ||
      oldDelegate.floatingRect != floatingRect ||
      oldDelegate.floatingImage != floatingImage ||
      oldDelegate.nativeImageSize != nativeImageSize ||
      oldDelegate.imageRect != imageRect ||
      oldDelegate.theme != theme;
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
