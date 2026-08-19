import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../models/annotation.dart';
import '../models/app_shortcut.dart';
import '../models/capture_item.dart';
import '../models/tool_properties.dart';
import '../services/capture_service.dart';
import '../services/clipboard_service.dart';
import '../services/database_service.dart';
import '../services/ocr/ocr_engine.dart';
import '../services/ocr/ocr_service.dart';
import '../services/render_service.dart';
import '../services/shortcut_service.dart';
import '../services/storage_service.dart';
import '../utils/canvas_projection.dart';
import '../utils/constants.dart';
import '../utils/image_operations.dart';
import '../utils/snip_theme.dart';
import 'components/header_bar.dart';
import 'components/ocr_result_panel.dart';
import 'components/style_picker.dart';
import 'components/tool_sidebar.dart';
import 'dialogs/about_dialog.dart';
import 'dialogs/save_as_dialog.dart';
import 'dialogs/shortcut_settings_dialog.dart';
import 'editor_canvas.dart';
import 'gallery_sidebar.dart';

/// Builds the root [ColorScheme] entirely from [t]'s tokens, filling every
/// M3 colour role explicitly rather than deriving one from a seed colour.
///
/// `ColorScheme.fromSeed` cannot be used here: its `SchemeTonalSpot`
/// algorithm hardcodes non-zero chroma for `secondary` (16), `tertiary`
/// (24), and every `*Container`/`outline`/`surfaceContainer*` role
/// *regardless of the seed colour's own chroma* — so even a perfectly
/// neutral seed like [SnipTheme.ink] leaks colour into roles this app never
/// reads directly, but that stock Material widgets do: an `AlertDialog`'s
/// icon defaults to `colorScheme.secondary`, its background to
/// `surfaceContainerHigh`, a `PopupMenuButton`'s highlight to `secondary`,
/// and so on. `copyWith`-ing a handful of roles after `fromSeed` is
/// whack-a-mole against a ~30-role scheme; constructing every role
/// explicitly removes the entire class of leak instead.
///
/// Only [SnipTheme.danger]/[SnipTheme.onDanger] are allowed to carry
/// chroma here — the one sanctioned exception, same as everywhere else in
/// this design language. `test/main_screen_color_scheme_test.dart` asserts
/// every other role stays neutral.
///
/// A top-level function (not a method on [_MainScreenState]) so it is
/// importable and unit-testable without pumping `MainScreen` — which
/// cannot be widget-tested (it builds an `EditorCanvas`, which emits
/// `Image.file`, which hangs `flutter_tester`).
ColorScheme snipColorScheme(SnipTheme t) {
  final brightness = t.isDark ? Brightness.dark : Brightness.light;
  return ColorScheme(
    brightness: brightness,
    primary: t.ink,
    onPrimary: t.onActive,
    primaryContainer: t.activeFill,
    onPrimaryContainer: t.onActive,
    primaryFixed: t.activeFill,
    primaryFixedDim: t.activeFill,
    onPrimaryFixed: t.onActive,
    onPrimaryFixedVariant: t.onActive,
    secondary: t.inkMuted,
    onSecondary: t.surfaceRaised,
    secondaryContainer: t.surfaceRaised,
    onSecondaryContainer: t.ink,
    secondaryFixed: t.surfaceRaised,
    secondaryFixedDim: t.surface,
    onSecondaryFixed: t.ink,
    onSecondaryFixedVariant: t.ink,
    tertiary: t.inkMuted,
    onTertiary: t.surfaceRaised,
    tertiaryContainer: t.surfaceRaised,
    onTertiaryContainer: t.ink,
    tertiaryFixed: t.surfaceRaised,
    tertiaryFixedDim: t.surface,
    onTertiaryFixed: t.ink,
    onTertiaryFixedVariant: t.ink,
    error: t.danger,
    onError: t.onDanger,
    errorContainer: t.danger,
    onErrorContainer: t.onDanger,
    surface: t.surface,
    onSurface: t.ink,
    surfaceDim: t.canvas,
    surfaceBright: t.surfaceRaised,
    surfaceContainerLowest: t.canvas,
    surfaceContainerLow: t.surface,
    surfaceContainer: t.surface,
    surfaceContainerHigh: t.surfaceRaised,
    surfaceContainerHighest: t.surfaceRaised,
    onSurfaceVariant: t.inkMuted,
    outline: t.border,
    outlineVariant: t.border,
    // Deliberately not per-mode: see SnipTheme.scrim's own doc comment.
    shadow: SnipTheme.scrim,
    scrim: SnipTheme.scrim,
    inverseSurface: t.activeFill,
    onInverseSurface: t.onActive,
    inversePrimary: t.onActive,
    // Killed rather than mapped: M3's default elevation overlay tints raised
    // surfaces with `surfaceTint` (normally `primary`), which would wash
    // higher-elevation panels with a visible grey overlay — exactly the kind
    // of unearned visual weight the hairline/flat skeleton language avoids.
    surfaceTint: Colors.transparent,
  );
}

/// Sentinel mirroring the one in the models so "leave unchanged" stays
/// distinguishable from "clear this colour".
const Object _unsetProperty = Object();

class CanvasSnapshot {
  final Uint8List? imageBytes;
  final List<Annotation> annotations;

  CanvasSnapshot({
    this.imageBytes,
    required this.annotations,
  });
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final CaptureService _captureService = CaptureService();
  final GlobalKey _repaintKey = GlobalKey();

  // App State
  final List<CaptureItem> _captures = [];
  CaptureItem? _activeCapture;

  List<Annotation> _annotations = [];

  /// Size of the bitmap the editor canvas has decoded, and the file it came
  /// from. The single source of truth for [_activeProjection] — see there.
  ({String path, Size size})? _decodedImage;
  final List<CanvasSnapshot> _undoStack = [];
  final List<CanvasSnapshot> _redoStack = [];
  static const int _maxUndoSteps = 80;
  int _imageRevision = 0;

  // Text extraction (OCR)
  final OcrService _ocrService = OcrService();

  /// Null while the result panel is closed. `OcrResult.empty` with no
  /// [_ocrUnavailableReason] is the genuine "ran, found nothing" state.
  OcrResult? _ocrResult;
  bool _isOcrRunning = false;
  String? _ocrUnavailableReason;

  /// Guards against an older extraction landing after a newer one. Region
  /// requests are never cached, so two quick drags really do race.
  int _ocrRequestToken = 0;

  /// Debounces persistence during high-frequency drag updates.
  Timer? _persistDebounce;

  /// Collapses a burst of property-slider edits into one undo step.
  String? _propertyUndoAnnotationId;
  DateTime _propertyUndoAt = DateTime.fromMillisecondsSinceEpoch(0);

  CanvasTool _activeTool = CanvasTool.select;
  final Map<CanvasTool, ToolProperties> _toolPropertiesMap = ToolProperties.createDefaults();
  double _rotation = 0.0;
  double _zoomScale = 1.0;
  int _stepCounter = 1;
  bool _isSidebarOpen = true;
  bool _isPropertiesOpen = true;
  bool _isCapturing = false;
  bool _isDarkMode = true;

  /// The resolved theme for the current [_isDarkMode] state.
  ///
  /// `MainScreen` is the widget that *establishes* [SnipThemeScope] — its
  /// `build()` constructs and returns it (see below). That means this
  /// State's own [context] sits above, not below, that scope:
  /// `SnipTheme.of(context)` walks context's ancestors, and there is no
  /// SnipThemeScope among them (`lib/main.dart` wraps `MainScreen` directly
  /// in a plain `MaterialApp`, nothing more) — it would never see the scope
  /// this same build() call mounts beneath it. So every chrome read that
  /// belongs to main_screen.dart itself is forced through [SnipTheme.forMode],
  /// hoisted here once rather than repeating the ternary at each call site.
  ///
  /// Any *descendant* widget — HeaderBar, ToolSidebar, StylePicker, the
  /// dialogs, GallerySidebar, OcrResultPanel, EditorCanvas (Tasks 3-6) — is
  /// mounted with its own BuildContext genuinely inside the scope this
  /// build() constructs, and should read via `SnipTheme.of(context)` instead.
  SnipTheme get _theme =>
      SnipTheme.forMode(_isDarkMode ? SnipThemeMode.dark : SnipThemeMode.light);

  String? _selectedAnnotationId;

  Annotation? get _selectedAnnotation {
    if (_selectedAnnotationId == null) return null;
    for (final a in _annotations) {
      if (a.id == _selectedAnnotationId) return a;
    }
    return null;
  }

  ToolProperties get _currentToolProperties {
    final targetTool = _selectedAnnotation?.tool ?? _activeTool;
    // Defensive fallback: `_toolPropertiesMap` is seeded with every
    // `CanvasTool` by `ToolProperties.createDefaults()`, so this branch is
    // never actually reached. The colour is chrome-adjacent rather than
    // annotation data, so it reads from the theme like everything else here.
    final t = _theme;
    return _toolPropertiesMap[targetTool] ?? ToolProperties(activeColor: t.ink);
  }

  /// Applies a property change to the active tool's defaults and, when an item
  /// is selected, to that item as well.
  ///
  /// [syncOnly] is used when the change originates from selecting an existing
  /// annotation — the tool defaults absorb its style but the annotation itself
  /// must not be rewritten (and no undo entry is recorded).
  void _updateActiveToolProperty({
    Color? activeColor,
    double? strokeWidth,
    double? opacity,
    double? fontSize,
    bool? isFilled,
    Object? textBackgroundColor = _unsetProperty,
    Object? fillColor = _unsetProperty,
    double? borderRadius,
    ShapeKind? shapeKind,
    LineStyle? lineStyle,
    BlurType? blurType,
    double? blurStrength,
    bool? hasShadow,
    bool? isDoubleArrow,
    double? fillTolerance,
    bool? isGlobalFill,
    bool syncOnly = false,
  }) {
    final selectedAnn = _selectedAnnotation;
    final targetTool = selectedAnn?.tool ?? _activeTool;

    if (!syncOnly && selectedAnn != null) {
      _pushPropertyUndoState(selectedAnn.id);
    }

    setState(() {
      final t = _theme;
      final currentProps =
          _toolPropertiesMap[targetTool] ?? ToolProperties(activeColor: t.ink);

      _toolPropertiesMap[targetTool] = currentProps.copyWith(
        activeColor: activeColor,
        strokeWidth: strokeWidth,
        opacity: opacity,
        fontSize: fontSize,
        isFilled: isFilled,
        textBackgroundColor: textBackgroundColor,
        fillColor: fillColor,
        borderRadius: borderRadius,
        shapeKind: shapeKind,
        lineStyle: lineStyle,
        blurType: blurType,
        blurStrength: blurStrength,
        hasShadow: hasShadow,
        isDoubleArrow: isDoubleArrow,
        fillTolerance: fillTolerance,
        isGlobalFill: isGlobalFill,
      );

      if (syncOnly || _selectedAnnotationId == null) return;

      final idx = _annotations.indexWhere((a) => a.id == _selectedAnnotationId);
      if (idx == -1) return;
      // Replace the list rather than mutating it in place: the canvas painter
      // compares element-wise against its previous list, and an in-place edit
      // leaves both references pointing at the same (already updated) object,
      // so the change would never repaint.
      _annotations = List<Annotation>.of(_annotations);
      // Two groups, deliberately separated. Colour, opacity, fill and the enum
      // properties mean the same thing in either coordinate space and are
      // written straight through. Stroke width, font size, corner radius and
      // blur sigma are lengths: the sliders produce canvas units but
      // `_annotations` holds image pixels, so they go through the projection.
      _annotations[idx] = _annotations[idx]
          .copyWith(
            color: activeColor,
            opacity: opacity,
            fill: isFilled,
            backgroundColor: textBackgroundColor,
            fillColor: fillColor,
            shapeKind: shapeKind,
            lineStyle: lineStyle,
            blurType: blurType,
            hasShadow: hasShadow,
            isDoubleArrow: isDoubleArrow,
          )
          .withCanvasSpaceScalars(
            _activeProjection,
            strokeWidth: strokeWidth,
            fontSize: fontSize,
            borderRadius: borderRadius,
            blurStrength: blurStrength,
          );
    });

    if (!syncOnly && _selectedAnnotationId != null) {
      _syncCurrentCaptureAnnotations();
    }
  }

  final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

  Map<AppShortcutAction, CustomShortcut> _shortcuts = ShortcutService.getDefaultShortcuts();

  @override
  void initState() {
    super.initState();
    _loadShortcuts();
    _loadHistory();
    _loadThemePreference();
  }

  @override
  void dispose() {
    // Flush any annotation edit still waiting on the debounce timer.
    _persistDebounce?.cancel();
    final pending = _activeCapture;
    // Same reasoning as the guard in _syncCurrentCaptureAnnotations: a
    // capture still waiting on legacy-coordinate conversion must not be
    // saved directly, since every save unconditionally stamps
    // coordSpace = imagePixels — closing the app on an unconverted legacy
    // capture before its post-frame conversion callback runs would otherwise
    // permanently mislabel its still-viewport annotations.
    if (pending != null && !pending.annotationsNeedConversion) {
      StorageService.saveCaptureItem(pending);
    }
    super.dispose();
  }

  Future<void> _loadThemePreference() async {
    final pref = await DatabaseService.getSetting('theme_mode');
    if (pref != null && mounted) {
      setState(() {
        _isDarkMode = pref == 'dark';
      });
    }
  }

  void _toggleThemeMode() {
    setState(() {
      _isDarkMode = !_isDarkMode;
    });
    DatabaseService.setSetting('theme_mode', _isDarkMode ? 'dark' : 'light');
  }

  void _openAboutDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AboutSnipSnapDialog(isDarkMode: _isDarkMode),
    );
  }

  int _findMaxStepNumber(List<Annotation> anns) {
    int maxStep = 0;
    for (final a in anns) {
      if (a.tool == CanvasTool.stepMarker && a.stepNumber != null) {
        if (a.stepNumber! > maxStep) maxStep = a.stepNumber!;
      }
    }
    return maxStep;
  }

  /// Mirrors the working annotation list onto the active capture and persists
  /// it.
  ///
  /// [debounce] is used for the high-frequency updates emitted while dragging;
  /// without it every pointer move would run a SQLite transaction.
  void _syncCurrentCaptureAnnotations({bool debounce = false}) {
    if (_activeCapture == null) return;

    // A legacy capture's annotations are still in viewport coordinates until
    // _convertActiveCaptureAnnotations runs and clears this flag. Every save
    // unconditionally stamps coordSpace = imagePixels on every row (see
    // DatabaseService._convertAnnotationToCompanion), so persisting here
    // before that conversion has actually happened would permanently
    // mislabel still-viewport data as image pixels. Nothing has touched
    // these annotations yet in that state, so skipping the write loses
    // nothing — the pending conversion will persist them once it runs.
    if (_activeCapture!.annotationsNeedConversion) return;

    final updatedItem = _activeCapture!.copyWith(annotations: List.from(_annotations));
    _activeCapture = updatedItem;

    final idx = _captures.indexWhere((c) => c.id == updatedItem.id);
    if (idx != -1) {
      _captures[idx] = updatedItem;
    }

    _persistDebounce?.cancel();
    if (!debounce) {
      StorageService.saveCaptureItem(updatedItem);
      return;
    }
    _persistDebounce = Timer(const Duration(milliseconds: 400), () {
      final pending = _activeCapture;
      // Must re-check the flag here, at fire time, not rely on the guard
      // above at schedule time: the active capture can change during the
      // 400ms window (e.g. the user switches to a legacy capture that still
      // needs conversion), and this callback always persists whatever
      // _activeCapture is when it actually fires.
      if (pending != null && !pending.annotationsNeedConversion) {
        StorageService.saveCaptureItem(pending);
      }
    });
  }

  Future<void> _loadHistory() async {
    final items = await StorageService.loadHistory();
    final savedSelectedId = await DatabaseService.getSetting('active_capture_id');

    if (mounted) {
      setState(() {
        _captures.clear();
        _captures.addAll(items);
        if (_captures.isNotEmpty) {
          CaptureItem targetItem = _captures.first;
          if (savedSelectedId != null) {
            final found = _captures.where((c) => c.id == savedSelectedId);
            if (found.isNotEmpty) {
              targetItem = found.first;
            }
          }
          _activeCapture = targetItem;
          _annotations = List.from(_activeCapture!.annotations);
          _stepCounter = _findMaxStepNumber(_annotations) + 1;
        }
      });

      if (_activeCapture != null && _activeCapture!.annotationsNeedConversion) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _convertActiveCaptureAnnotations();
        });
      }
    }
  }

  /// One-time migration of a pre-v4 capture's annotations into image pixels.
  Future<void> _convertActiveCaptureAnnotations() async {
    final original = _activeCapture;
    if (original == null || !original.annotationsNeedConversion) return;

    var capture = original;

    // Captures written before Task 1 have no recorded dimensions, which is the
    // common case for existing installs. Decode once to recover them.
    if (!capture.hasDimensions) {
      try {
        final decoded = img.decodeImage(await File(capture.filePath).readAsBytes());
        if (decoded == null) return;
        capture = capture.copyWith(width: decoded.width, height: decoded.height);
      } catch (e) {
        debugPrint('SnipSnap legacy dimension read error: $e');
        return;
      }
      // The decode above is the only await in this method. If the user
      // switched to a different capture while it was in flight, _activeCapture
      // now points elsewhere: abort without writing anything, so we neither
      // map the newly-selected capture's annotations against this capture's
      // dimensions nor clobber the user's new selection by overwriting
      // _activeCapture with this stale one. The newly active capture (if it
      // also needs conversion) schedules its own run.
      if (!mounted || _activeCapture?.id != original.id) return;
    }

    final imageSize = Size(capture.width.toDouble(), capture.height.toDouble());
    final result = convertLegacyAnnotationsChecked(
      annotations: _annotations,
      imageSize: imageSize,
      canvasSize: _canvasSize,
    );

    // A degenerate canvas means the projection was invalid and nothing was
    // actually converted (convertLegacyAnnotationsChecked returned the input
    // untouched). Leave annotationsNeedConversion set so a later load, once
    // the canvas has a real size, retries instead of permanently mislabeling
    // still-viewport data as image pixels.
    if (!result.converted) return;

    final resolved = capture;
    setState(() {
      _annotations = result.annotations;
      _activeCapture = resolved.copyWith(
        annotationsNeedConversion: false,
        annotations: result.annotations,
      );
    });
    // Rewrites the rows with coordSpace = imagePixels so this never runs again.
    _syncCurrentCaptureAnnotations();
  }

  Future<void> _loadShortcuts() async {
    final loaded = await ShortcutService.loadShortcuts();
    if (mounted) {
      setState(() {
        _shortcuts = loaded;
      });
      _registerGlobalHotKeys();
    }
  }

  Future<void> _registerGlobalHotKeys() async {
    await ShortcutService.registerGlobalHotKeys(
      shortcuts: _shortcuts,
      onHotKeyTriggered: (action) {
        final handler = _getHandlerForAction(action);
        if (handler != null) {
          handler();
        }
      },
    );
  }

  void _openShortcutSettingsDialog() {
    showDialog(
      context: context,
      builder: (ctx) => ShortcutSettingsDialog(
        initialShortcuts: _shortcuts,
        isDarkMode: _isDarkMode,
        onShortcutsSaved: (updatedShortcuts) {
          setState(() {
            _shortcuts = updatedShortcuts;
          });
          _registerGlobalHotKeys();
        },
      ),
    );
  }

  VoidCallback? _getHandlerForAction(AppShortcutAction action) {
    switch (action) {
      case AppShortcutAction.interactiveSnip:
        return _handleInteractiveCapture;
      case AppShortcutAction.fullScreenSnip:
        return _handleFullScreenCapture;
      case AppShortcutAction.timerSnip:
        return _handleTimerCapture;
      case AppShortcutAction.openImage:
        return _handleImportImage;
      case AppShortcutAction.copyToClipboard:
        return _handleCopyToClipboard;
      case AppShortcutAction.saveAs:
        return _handleSaveAs;
      case AppShortcutAction.undo:
        return _undoStack.isNotEmpty ? _undo : null;
      case AppShortcutAction.redo:
        return _redoStack.isNotEmpty ? _redo : null;
      case AppShortcutAction.clearAnnotations:
        return _annotations.isNotEmpty ? _clearAnnotations : null;
      case AppShortcutAction.toggleHistory:
        return () => setState(() => _isSidebarOpen = !_isSidebarOpen);
      case AppShortcutAction.flattenCanvas:
        return _annotations.isNotEmpty ? _handleFlattenCanvas : null;
    }
  }

  Map<ShortcutActivator, VoidCallback> _buildShortcutBindings() {
    final bindings = <ShortcutActivator, VoidCallback>{};
    for (final entry in _shortcuts.entries) {
      final handler = _getHandlerForAction(entry.key);
      if (handler != null) {
        bindings[entry.value.toSingleActivator()] = handler;
      }
    }
    return bindings;
  }

  /// Records an undo checkpoint.
  ///
  /// Bitmap pixels are only snapshotted for operations that actually rewrite
  /// the image file (crop, flatten, flood fill). Vector-only edits store just
  /// the annotation list, which keeps the history cheap — a full-resolution
  /// screenshot copy per annotation would exhaust memory in a long session.
  Future<void> _pushUndoState({Uint8List? imageBytes, bool captureImage = false}) async {
    _propertyUndoAnnotationId = null;

    Uint8List? bytes = imageBytes;
    if (bytes == null &&
        captureImage &&
        _activeCapture != null &&
        File(_activeCapture!.filePath).existsSync()) {
      bytes = await File(_activeCapture!.filePath).readAsBytes();
    }

    _undoStack.add(CanvasSnapshot(
      imageBytes: bytes,
      annotations: List.from(_annotations),
    ));
    _trimUndoStack();
    _redoStack.clear();
  }

  void _trimUndoStack() {
    while (_undoStack.length > _maxUndoSteps) {
      _undoStack.removeAt(0);
    }
  }

  /// Coalesces the stream of checkpoints produced while a property slider is
  /// being dragged into a single undo step per item per pause.
  void _pushPropertyUndoState(String annotationId) {
    final now = DateTime.now();
    if (_propertyUndoAnnotationId == annotationId &&
        now.difference(_propertyUndoAt) < const Duration(milliseconds: 900)) {
      _propertyUndoAt = now;
      return;
    }
    _propertyUndoAnnotationId = annotationId;
    _propertyUndoAt = now;

    _undoStack.add(CanvasSnapshot(annotations: List.from(_annotations)));
    _trimUndoStack();
    _redoStack.clear();
  }

  /// The key `OcrService` caches full-image results under.
  ///
  /// The service cannot see the bitmap change underneath it, so invalidation is
  /// entirely the caller's job. Three components, each covering a different way
  /// the bytes at [CaptureItem.filePath] can stop matching a cached result:
  ///
  /// * the capture id — a different capture is a different image;
  /// * the file path — the same capture can be repointed at another file;
  /// * [_imageRevision] — bumped by crop, flatten, flood fill, undo/redo and
  ///   the canvas's own cut/move/delete of a floating selection, i.e. every
  ///   operation that rewrites the file in place while the id and the path
  ///   both stay the same. All of them go through [_bumpImageRevision]. It only ever increments and is never reset,
  ///   so a key can never be reused for different pixels — undo does not walk
  ///   it back onto the pre-edit key, it moves forward onto a fresh one and
  ///   simply re-runs.
  String _ocrCacheKeyFor(CaptureItem capture) =>
      '${capture.id}|${capture.filePath}|$_imageRevision';

  /// Runs OCR over the active capture, optionally limited to [imageRegionPx]
  /// (native image pixels — `EditorCanvas` has already projected it).
  Future<void> _handleExtractText(Rect? imageRegionPx) async {
    final capture = _activeCapture;
    if (capture == null) return;

    final token = ++_ocrRequestToken;

    // "Unavailable" and "found nothing" both come back from the service as an
    // empty result. Probing availability first is the only way to tell the
    // user which one happened.
    final availability = await _ocrService.availability();
    if (!mounted || token != _ocrRequestToken) return;
    if (!availability.available) {
      setState(() {
        _isOcrRunning = false;
        _ocrUnavailableReason = availability.reason ??
            'Text extraction is not available on this system.';
        _ocrResult = OcrResult.empty;
      });
      return;
    }

    setState(() {
      _isOcrRunning = true;
      _ocrUnavailableReason = null;
      _ocrResult = OcrResult.empty;
    });

    final result = await _ocrService.recognizeCapture(
      imagePath: capture.filePath,
      cacheKey: _ocrCacheKeyFor(capture),
      regionPx: imageRegionPx,
    );

    if (!mounted || token != _ocrRequestToken) return;
    setState(() {
      _isOcrRunning = false;
      _ocrResult = result;
    });
  }

  /// The one way the bitmap generation advances.
  ///
  /// Every in-place rewrite of the capture file has to come through here, not
  /// through a bare increment of the counter: it is what makes the OCR cache
  /// key stop matching, and `_resetOcr` is what stops the open panel from going
  /// on displaying text read out of the previous bitmap. Splitting the two
  /// invites a call site that does one and forgets the other.
  ///
  /// Callers are already inside `setState`; this deliberately does not wrap
  /// itself in another one.
  void _bumpImageRevision() {
    _imageRevision++;
    _resetOcr();
  }

  /// Drops the extracted text onto the canvas as a text annotation.
  ///
  /// Two different coordinate obligations meet here and only one of them is
  /// the rect contract:
  ///
  /// * `startPoint` is already in **image pixels**, the space annotations are
  ///   stored in, because this goes through [_onAnnotationAdded] — the
  ///   storage-side path, which does not convert. Nothing to do.
  /// * the scale-dependent **scalars** are not. `ToolProperties.fontSize` and
  ///   friends are the numbers the toolbar sliders show, which are canvas
  ///   units by definition. Writing 18.0 straight into an image-space
  ///   annotation means `mappedToCanvasSpace` divides it by the projection
  ///   scale at paint time, so on a Retina capture the inserted text renders
  ///   at 5-9 canvas pixels and persists that way to disk. That is exactly
  ///   what `Annotation.withCanvasSpaceScalars` exists to prevent, and it is
  ///   the same helper the property sliders go through.
  ///
  /// A degenerate projection cannot convert anything, so the insert is refused
  /// outright rather than silently storing canvas numbers as image pixels —
  /// consistent with `withCanvasSpaceScalars`' own contract, which would
  /// otherwise leave the model defaults in place and look like it worked.
  void _insertExtractedText(String text) {
    final projection = _activeProjection;
    if (projection == null || !projection.isValid) {
      _showToast('Cannot insert text until the image has finished loading');
      return;
    }

    // The Text tool's own defaults, not `_currentToolProperties` — that would
    // read the OCR tool's placeholder style and drop an accent-coloured
    // caption at the wrong size.
    final style = _toolPropertiesMap[CanvasTool.text] ??
        const ToolProperties(activeColor: Colors.white);

    final annotation = Annotation(
      id: const Uuid().v4(),
      tool: CanvasTool.text,
      color: style.activeColor,
      backgroundColor: style.textBackgroundColor,
      fill: style.isFilled,
      opacity: style.opacity,
      text: text,
      startPoint: const Offset(40, 40),
    ).withCanvasSpaceScalars(
      projection,
      strokeWidth: style.strokeWidth,
      fontSize: style.fontSize,
      borderRadius: style.borderRadius,
      blurStrength: style.blurStrength,
    );

    _onAnnotationAdded(annotation);
    setState(() {
      _ocrResult = null;
      _ocrUnavailableReason = null;
      // Switching to Select lets the user click the new label and drag it into
      // place. The canvas owns its own selection state with no inbound prop,
      // so this deliberately does *not* set `_selectedAnnotationId` — that
      // would point the sliders and Delete at an annotation the canvas draws
      // without handles.
      _activeTool = CanvasTool.select;
    });
  }

  /// Closes the panel and drops every cached page. Called whenever the editor
  /// switches to a different bitmap.
  void _resetOcr() {
    _ocrService.clearCache();
    _ocrRequestToken++;
    _ocrResult = null;
    _isOcrRunning = false;
    _ocrUnavailableReason = null;
  }

  void _onAnnotationAdded(Annotation annotation) {
    _pushUndoState();
    setState(() {
      _annotations = [..._annotations, annotation];
    });
    _syncCurrentCaptureAnnotations();
  }

  void _deleteSelectedAnnotation() {
    if (_selectedAnnotationId == null) return;
    _pushUndoState();
    final deletingAnn = _annotations.where((a) => a.id == _selectedAnnotationId).firstOrNull;
    final remaining = _annotations.where((a) => a.id != _selectedAnnotationId).toList();

    // Auto re-sequence step markers if a step marker was deleted
    if (deletingAnn != null && deletingAnn.tool == CanvasTool.stepMarker) {
      int step = 1;
      final resequenced = remaining.map((ann) {
        if (ann.tool == CanvasTool.stepMarker) {
          final updated = ann.copyWith(stepNumber: step);
          step++;
          return updated;
        }
        return ann;
      }).toList();
      setState(() {
        _annotations = resequenced;
        _selectedAnnotationId = null;
        _stepCounter = step;
      });
    } else {
      setState(() {
        _annotations = remaining;
        _selectedAnnotationId = null;
      });
    }
    _syncCurrentCaptureAnnotations();
  }

  void _renumberStepMarkers() {
    _pushUndoState();
    int currentStep = 1;
    final updated = _annotations.map((ann) {
      if (ann.tool == CanvasTool.stepMarker) {
        final renumbered = ann.copyWith(stepNumber: currentStep);
        currentStep++;
        return renumbered;
      }
      return ann;
    }).toList();

    setState(() {
      _annotations = updated;
      _stepCounter = currentStep;
    });
    _syncCurrentCaptureAnnotations();
    _showToast('Step numbers resequenced (1 to ${currentStep - 1})');
  }

  /// Moves the selected annotation to the top or the bottom of the paint order.
  void _reorderSelectedAnnotation({required bool toFront}) {
    if (_selectedAnnotationId == null) return;
    final idx = _annotations.indexWhere((a) => a.id == _selectedAnnotationId);
    if (idx == -1) return;
    if (toFront && idx == _annotations.length - 1) return;
    if (!toFront && idx == 0) return;

    _pushUndoState();
    setState(() {
      final reordered = List<Annotation>.of(_annotations);
      final item = reordered.removeAt(idx);
      if (toFront) {
        reordered.add(item);
      } else {
        reordered.insert(0, item);
      }
      _annotations = reordered;
    });
    _syncCurrentCaptureAnnotations();
  }

  void _onAnnotationsUpdated(List<Annotation> updatedList) {
    _pushUndoState();
    setState(() {
      _annotations = List.from(updatedList);
    });
    _syncCurrentCaptureAnnotations();
  }

  /// Live update during drag/resize/rotate – no undo push (undo is pushed once
  /// at gesture start) and the database write is debounced.
  void _onAnnotationsLiveUpdated(List<Annotation> updatedList) {
    setState(() {
      _annotations = List.from(updatedList);
    });
    _syncCurrentCaptureAnnotations(debounce: true);
  }

  Future<void> _applyHistorySnapshot(
    CanvasSnapshot snapshot,
    List<CanvasSnapshot> pushTo,
  ) async {
    // Only carry bitmap pixels into the opposite stack when the step being
    // reversed actually changed them.
    Uint8List? currentBytes;
    if (snapshot.imageBytes != null &&
        _activeCapture != null &&
        File(_activeCapture!.filePath).existsSync()) {
      currentBytes = await File(_activeCapture!.filePath).readAsBytes();
    }
    pushTo.add(CanvasSnapshot(
      imageBytes: currentBytes,
      annotations: List.from(_annotations),
    ));

    if (snapshot.imageBytes != null && _activeCapture != null) {
      await _replaceActiveImageBytes(snapshot.imageBytes!);
    }

    setState(() {
      _bumpImageRevision();
      _annotations = List.from(snapshot.annotations);
      _selectedAnnotationId = null;
      _stepCounter = _findMaxStepNumber(snapshot.annotations) + 1;
    });
    _syncCurrentCaptureAnnotations();
  }

  Future<void> _undo() async {
    if (_undoStack.isEmpty) return;
    _propertyUndoAnnotationId = null;
    await _applyHistorySnapshot(_undoStack.removeLast(), _redoStack);
  }

  Future<void> _redo() async {
    if (_redoStack.isEmpty) return;
    _propertyUndoAnnotationId = null;
    await _applyHistorySnapshot(_redoStack.removeLast(), _undoStack);
  }

  void _clearAnnotations() {
    if (_annotations.isNotEmpty) {
      _pushUndoState();
      setState(() {
        _annotations = [];
      });
      _syncCurrentCaptureAnnotations();
    }
  }

  // Capture Triggers
  Future<void> _handleInteractiveCapture() async {
    setState(() => _isCapturing = true);
    final path = await _captureService.captureInteractive();
    setState(() => _isCapturing = false);
    if (path != null) {
      await _addCaptureFromPath(path);
    }
  }

  Future<void> _handleFullScreenCapture() async {
    setState(() => _isCapturing = true);
    final path = await _captureService.captureFullScreen();
    setState(() => _isCapturing = false);
    if (path != null) {
      await _addCaptureFromPath(path);
    }
  }

  Future<void> _handleTimerCapture() async {
    setState(() => _isCapturing = true);
    final t = _theme;
    _scaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(
          'Capturing in 3 seconds... Prepare your screen!',
          style: TextStyle(color: t.onActive, fontWeight: FontWeight.bold),
        ),
        duration: const Duration(seconds: 3),
        backgroundColor: t.activeFill,
      ),
    );
    final path = await _captureService.captureTimer(3);
    setState(() => _isCapturing = false);
    if (path != null) {
      await _addCaptureFromPath(path);
    }
  }

  Future<void> _handleImportImage() async {
    try {
      final result = await FilePicker.pickFile(
        type: FileType.image,
        dialogTitle: 'Select Image File',
      );
      if (result != null && result.path != null) {
        final path = await _captureService.importImage(result.path!);
        if (path != null) {
          await _addCaptureFromPath(path);
        }
      }
    } catch (e) {
      debugPrint('SnipSnap import image error: $e');
      _showToast('Failed to pick image file: ${e.toString()}');
    }
  }

  Future<void> _addCaptureFromPath(String path) async {
    _syncCurrentCaptureAnnotations();

    int width = 0;
    int height = 0;
    try {
      final decoded = img.decodeImage(await File(path).readAsBytes());
      if (decoded != null) {
        width = decoded.width;
        height = decoded.height;
      }
    } catch (e) {
      debugPrint('SnipSnap dimension read error: $e');
    }

    final now = DateTime.now();
    final newItem = CaptureItem(
      id: '${now.millisecondsSinceEpoch}_${_captures.length}',
      filePath: path,
      title: 'Snap ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}',
      createdAt: now,
      width: width,
      height: height,
    );

    setState(() {
      _resetOcr();
      _captures.insert(0, newItem);
      _activeCapture = newItem;
      _annotations = [];
      _undoStack.clear();
      _redoStack.clear();
      _stepCounter = 1;
    });
    StorageService.saveHistory(_captures);
    DatabaseService.setSetting('active_capture_id', newItem.id);
  }

  /// Size of the editor canvas the annotations were laid out against, or
  /// [Size.zero] before it has been laid out. Mirrors `EditorCanvas._canvasSize`
  /// — both read the same render box through the same key, and both report the
  /// degenerate case rather than substituting a made-up default.
  Size get _canvasSize {
    final renderObj = _repaintKey.currentContext?.findRenderObject();
    if (renderObj is RenderBox && renderObj.hasSize) return renderObj.size;
    return Size.zero;
  }

  /// The image <-> canvas mapping for the active capture as it is laid out
  /// right now, or null when nothing can be mapped (nothing decoded yet, the
  /// decode belongs to a different file, or a canvas that has not been laid
  /// out yet).
  ///
  /// The image size comes from the decoded bitmap the editor is actually
  /// showing, never from [CaptureItem.width]/[CaptureItem.height]. The
  /// recorded dimensions are a persisted copy that any operation rewriting the
  /// file can leave behind — undo after a crop restores the pre-crop bitmap
  /// without restoring the row — and a projection built from a stale size
  /// silently rescales every later edit. Reading the decode makes staleness
  /// impossible instead of merely unlikely, and keeps this in exact agreement
  /// with `EditorCanvas`, which projects through the same bitmap.
  CanvasProjection? get _activeProjection {
    final capture = _activeCapture;
    final decoded = _decodedImage;
    // The path check rejects a decode left over from a capture the user has
    // since switched away from.
    if (capture == null || decoded == null || decoded.path != capture.filePath) {
      return null;
    }
    final projection = CanvasProjection(
      imageSize: decoded.size,
      canvasSize: _canvasSize,
    );
    return projection.isValid ? projection : null;
  }

  /// Native pixel size of the bitmap the editor canvas currently has decoded,
  /// tagged with the file it came from. Reported by [EditorCanvas] every time
  /// it (re)loads, which covers capture switches and every `_imageRevision`
  /// bump — crop, flatten, undo, redo and flood fill alike.
  void _handleImageSizeResolved(String imagePath, Size imageSize) {
    if (imageSize.isEmpty) return;
    if (_decodedImage?.path == imagePath && _decodedImage?.size == imageSize) {
      return;
    }

    final capture = _activeCapture;
    // The file on disk is the authority, so a recorded size that disagrees
    // with it is repaired here rather than left to rot. This is what makes an
    // undo that restores a pre-crop bitmap also restore the recorded row.
    final isActive = capture != null && capture.filePath == imagePath;
    final needsRepair = isActive &&
        (capture.width != imageSize.width.round() ||
            capture.height != imageSize.height.round());

    setState(() {
      _decodedImage = (path: imagePath, size: imageSize);
      if (needsRepair) {
        _activeCapture = capture.copyWith(
          width: imageSize.width.round(),
          height: imageSize.height.round(),
        );
      }
    });

    if (needsRepair) _syncCurrentCaptureAnnotations();
  }

  /// True when the active capture's annotations are still pre-v4 viewport
  /// numbers, i.e. its post-frame conversion has not run (or could not run,
  /// because the canvas was not laid out yet).
  ///
  /// Everything that burns markup into the bitmap — export, flatten, crop —
  /// treats `_annotations` as image pixels and would place every mark at the
  /// wrong coordinates and weight. Flatten and crop rewrite the capture file,
  /// so that mistake is not recoverable. Refuse loudly, matching the
  /// "the editor is not ready" contract the export and crop paths already use
  /// for a degenerate canvas.
  bool _blockedByPendingConversion(String action) {
    if (!(_activeCapture?.annotationsNeedConversion ?? false)) return false;
    _showToast('Cannot $action yet: this capture is still being upgraded. '
        'Try again in a moment.');
    return true;
  }

  /// Renders the active capture with its annotations burned in, at the source
  /// image's native resolution and with no editor chrome.
  Future<Uint8List?> _renderAnnotatedBytes() async {
    final capture = _activeCapture;
    if (capture == null) return null;
    // Covers copy-to-clipboard and Save As, and is the second line of defence
    // for flatten and crop, which check before touching the undo stack.
    if (_blockedByPendingConversion('export')) return null;

    try {
      final bytes = await RenderService.renderFlattenedPng(
        imagePath: capture.filePath,
        annotations: _annotations,
        canvasSize: _canvasSize,
      );
      if (bytes != null) return bytes;
    } on StateError catch (e) {
      // The canvas has no size, so the annotations cannot be placed. Say so
      // instead of handing back a file that quietly lost its markup.
      debugPrint('SnipSnap export error: $e');
      _showToast('Could not export: the editor is not ready. Try again.');
      return null;
    }

    // Fall back to the untouched source file rather than failing the export.
    if (File(capture.filePath).existsSync()) {
      return await File(capture.filePath).readAsBytes();
    }
    return null;
  }

  Future<void> _handleCopyToClipboard() async {
    if (_activeCapture == null) {
      _showToast('No screenshot to copy!');
      return;
    }

    final bytes = await _renderAnnotatedBytes();
    if (bytes != null) {
      final tempPath = await StorageService.saveTempImage(bytes);
      final success = await ClipboardService.copyImageToClipboard(tempPath);
      if (success) {
        _showToast('Copied screenshot to clipboard!');
      } else {
        _showToast('Failed to copy image');
      }
    }
  }

  Future<void> _handleSaveAs() async {
    if (_activeCapture == null) {
      _showToast('No screenshot to save!');
      return;
    }

    final bytes = await _renderAnnotatedBytes();
    if (bytes == null) {
      _showToast('Failed to render screenshot bytes');
      return;
    }

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (ctx) => SaveAsDialog(
        initialName: _activeCapture!.title,
        isDarkMode: _isDarkMode,
        onConfirm: (options) async {
          await Future.delayed(const Duration(milliseconds: 150));
          final gradient = (options.gradientIndex != null &&
                  options.gradientIndex! >= 0 &&
                  options.gradientIndex! < AppColors.framingGradients.length)
              ? AppColors.framingGradients[options.gradientIndex!]
              : null;

          final wantsFraming = options.framingPadding > 0 ||
              options.cornerRadius > 0 ||
              options.shadowBlur > 0 ||
              gradient != null;

          Uint8List exportBytes = bytes;
          if (wantsFraming) {
            // Re-renders from scratch because framing changes the output
            // dimensions. The canvas can have gone away since the dialog
            // opened, so this call carries the same loud-failure contract as
            // the one in _renderAnnotatedBytes.
            try {
              exportBytes = await RenderService.renderFlattenedPng(
                    imagePath: _activeCapture!.filePath,
                    annotations: _annotations,
                    canvasSize: _canvasSize,
                    framingPadding: options.framingPadding,
                    cornerRadius: options.cornerRadius,
                    shadowBlur: options.shadowBlur,
                    framingGradient: gradient,
                  ) ??
                  bytes;
            } on StateError catch (e) {
              debugPrint('SnipSnap export error: $e');
              _showToast('Could not export: the editor is not ready. Try again.');
              return;
            }
          }

          final savedPath = await StorageService.exportImageDialogWithFormat(
            bytes: exportBytes,
            fileName: options.fileName,
            isJpg: options.format == SaveFormat.jpg,
            jpgQuality: options.quality,
            customFolderPath: options.customFolderPath,
          );
          if (savedPath != null) {
            _showToast('Saved screenshot to: ${p.basename(savedPath)}');
          } else {
            _showToast('Save cancelled');
          }
        },
      ),
    );
  }

  /// Writes [bytes] over the active capture's file and forces every image cache
  /// layer to drop the stale bitmap so the canvas updates immediately.
  Future<void> _replaceActiveImageBytes(Uint8List bytes) async {
    final targetPath = _activeCapture!.filePath;
    await File(targetPath).writeAsBytes(bytes);
    await FileImage(File(targetPath)).evict();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  }

  Future<void> _handleFlattenCanvas() async {
    if (_activeCapture == null) {
      _showToast('No screenshot to flatten!');
      return;
    }
    if (_annotations.isEmpty) {
      _showToast('No annotations to flatten!');
      return;
    }
    // Before the undo push, not after: flatten rewrites the capture file, and
    // an aborted flatten should leave no orphan undo entry behind.
    if (_blockedByPendingConversion('flatten')) return;

    await _pushUndoState(captureImage: true);

    final bytes = await _renderAnnotatedBytes();
    if (bytes == null) {
      _showToast('Failed to flatten canvas');
      return;
    }

    await _replaceActiveImageBytes(bytes);

    setState(() {
      _bumpImageRevision();
      _annotations = [];
      _stepCounter = 1;
    });
    _syncCurrentCaptureAnnotations();

    _showToast('Canvas flattened! Annotations baked into image.');
  }

  Future<void> _handleApplyCrop(Rect cropRect) async {
    if (_activeCapture == null || !File(_activeCapture!.filePath).existsSync()) return;
    // Crop bakes the markup in before cutting, and rewrites the file. Checked
    // here rather than relying on _renderAnnotatedBytes returning null, because
    // this path falls back to the un-annotated original on a null render — so
    // without this the crop would silently proceed and drop the markup
    // entirely instead of refusing.
    if (_blockedByPendingConversion('crop')) return;

    try {
      final canvasSize = _canvasSize;
      final originalBytes = await File(_activeCapture!.filePath).readAsBytes();

      // Push the pre-crop image *and* annotations so a single undo restores
      // both.
      await _pushUndoState(imageBytes: originalBytes);

      // Bake annotations in before cropping so markup survives the operation
      // instead of being discarded.
      final sourceBytes = _annotations.isEmpty
          ? originalBytes
          : (await _renderAnnotatedBytes() ?? originalBytes);

      final decoded = img.decodeImage(sourceBytes);
      if (decoded == null) return;

      final imageRect = RenderService.imageRectInCanvas(
        imageSize: Size(decoded.width.toDouble(), decoded.height.toDouble()),
        canvasSize: canvasSize,
      );
      if (imageRect.isEmpty) {
        // Same reasoning as the export path: without a laid-out canvas the crop
        // rectangle cannot be placed on the image at all, and silently doing
        // nothing reads to the user as a broken button.
        _showToast('Could not crop: the editor is not ready. Try again.');
        return;
      }

      // Canvas coordinates -> native image pixels.
      final scaleX = decoded.width / imageRect.width;
      final scaleY = decoded.height / imageRect.height;

      final relLeft = cropRect.left - imageRect.left;
      final relTop = cropRect.top - imageRect.top;
      final relRight = cropRect.right - imageRect.left;
      final relBottom = cropRect.bottom - imageRect.top;
      if (relRight - relLeft <= 5 || relBottom - relTop <= 5) return;

      final targetLeft = (relLeft * scaleX).round();
      final targetTop = (relTop * scaleY).round();
      final targetWidth = ((relRight - relLeft) * scaleX).round();
      final targetHeight = ((relBottom - relTop) * scaleY).round();

      final result = ImageOperations.expandOrCropCanvas(
        sourceImage: decoded,
        targetLeft: targetLeft,
        targetTop: targetTop,
        targetWidth: targetWidth,
        targetHeight: targetHeight,
      );

      await _replaceActiveImageBytes(Uint8List.fromList(img.encodePng(result)));

      setState(() {
        _bumpImageRevision();
        _annotations = [];
        _selectedAnnotationId = null;
        _activeTool = CanvasTool.select;
        // The file on disk is a different size now. The recorded dimensions
        // feed every projection built from this capture — the toolbar's
        // canvas -> image conversion and the legacy annotation migration — so
        // leaving them stale silently rescales everything drawn after a crop.
        _activeCapture = _activeCapture!.copyWith(
          width: result.width,
          height: result.height,
        );
      });
      _syncCurrentCaptureAnnotations();

      final isExpanded = targetLeft < 0 ||
          targetTop < 0 ||
          targetLeft + targetWidth > decoded.width ||
          targetTop + targetHeight > decoded.height;
      _showToast(isExpanded
          ? 'Canvas expanded to ${result.width} × ${result.height} px (Cmd+Z to undo)'
          : 'Cropped to ${result.width} × ${result.height} px (Cmd+Z to undo)');
    } catch (e) {
      debugPrint('SnipSnap crop error: $e');
      _showToast('Failed to crop image');
    }
  }

  void _showToast(String message) {
    final t = _theme;
    final toastBg = t.surfaceRaised;
    final textColor = t.ink;
    final borderColor = t.border;

    _scaffoldMessengerKey.currentState?.hideCurrentSnackBar();
    _scaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(message, style: TextStyle(color: textColor, fontWeight: FontWeight.w600)),
        backgroundColor: toastBg,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: borderColor),
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // This State's own `context` sits above the SnipThemeScope built below,
    // so `_theme` (SnipTheme.forMode, not .of(context)) is the only option
    // here too — see `_theme`'s doc comment for why.
    final theme = _theme;

    return SnipThemeScope(
      theme: theme,
      child: MaterialApp(
      scaffoldMessengerKey: _scaffoldMessengerKey,
      title: 'SnipSnap - Screen Capture & Markup',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: theme.isDark ? Brightness.dark : Brightness.light,
        scaffoldBackgroundColor: theme.canvas,
        colorScheme: snipColorScheme(theme),
        textTheme: GoogleFonts.interTextTheme(
          theme.isDark ? ThemeData.dark().textTheme : ThemeData.light().textTheme,
        ).apply(bodyColor: theme.ink, displayColor: theme.ink),
        dividerColor: theme.border,
      ),
      home: Scaffold(
        backgroundColor: theme.canvas,
        body: CallbackShortcuts(
        bindings: _buildShortcutBindings(),
        child: Focus(
          autofocus: true,
          child: Column(
            children: [
              // Top Header Bar
              HeaderBar(
                onSnipInteractive: _handleInteractiveCapture,
                onSnipFullScreen: _handleFullScreenCapture,
                onSnipTimer: _handleTimerCapture,
                onImportImage: _handleImportImage,
                onUndo: _undo,
                onRedo: _redo,
                onClear: _clearAnnotations,
                onCopyToClipboard: _handleCopyToClipboard,
                onSaveAs: _handleSaveAs,
                onFlattenCanvas: _annotations.isNotEmpty ? _handleFlattenCanvas : null,
                onToggleSidebar: () => setState(() => _isSidebarOpen = !_isSidebarOpen),
                onToggleProperties: () => setState(() => _isPropertiesOpen = !_isPropertiesOpen),
                isPropertiesOpen: _isPropertiesOpen,
                onOpenShortcutSettings: _openShortcutSettingsDialog,
                onToggleThemeMode: _toggleThemeMode,
                onOpenAboutDialog: _openAboutDialog,
                canUndo: _undoStack.isNotEmpty,
                canRedo: _redoStack.isNotEmpty,
                canClear: _annotations.isNotEmpty,
                hasCapture: _activeCapture != null,
                isSidebarOpen: _isSidebarOpen,
                isDarkMode: _isDarkMode,
                shortcuts: _shortcuts,
                zoomScale: _zoomScale,
                onZoomScaleChanged: (val) => setState(() => _zoomScale = val),
              ),

              // Main Work Area (Canvas + Right Properties Sidebar)
              Expanded(
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Row(
                      children: [
                        // Slim Left Sidebar Tools
                        ToolSidebar(
                          activeTool: _activeTool,
                          onToolSelected: (tool) => setState(() => _activeTool = tool),
                          shapeKind: _currentToolProperties.shapeKind,
                          onShapeKindSelected: (kind) => _updateActiveToolProperty(shapeKind: kind),
                          isSidebarOpen: _isSidebarOpen,
                          onToggleSidebar: () => setState(() => _isSidebarOpen = !_isSidebarOpen),
                          isDarkMode: _isDarkMode,
                        ),

                        // Editor Canvas
                        Expanded(
                          child: EditorCanvas(
                            imagePath: _activeCapture?.filePath,
                            annotations: _annotations,
                            activeTool: _activeTool,
                            onToolSelected: (tool) => setState(() => _activeTool = tool),
                            onSelectAnnotation: (ann) {
                              setState(() {
                                _selectedAnnotationId = ann?.id;
                                if (ann != null) {
                                  _isPropertiesOpen = true;
                                }
                              });
                              if (ann != null) {
                                // Adopt the item's style into the tool defaults
                                // without rewriting the item or logging undo.
                                _updateActiveToolProperty(
                                  syncOnly: true,
                                  activeColor: ann.color,
                                  textBackgroundColor: ann.backgroundColor,
                                  fillColor: ann.fillColor,
                                  strokeWidth: ann.strokeWidth,
                                  fontSize: ann.fontSize,
                                  opacity: ann.opacity,
                                  isFilled: ann.fill,
                                  borderRadius: ann.borderRadius,
                                  shapeKind: ann.shapeKind,
                                  lineStyle: ann.lineStyle,
                                  blurType: ann.blurType,
                                  blurStrength: ann.blurStrength,
                                  hasShadow: ann.hasShadow,
                                  isDoubleArrow: ann.isDoubleArrow,
                                );
                                setState(() {
                                  _rotation = ann.rotation;
                                });
                              }
                            },
                            activeColor: _currentToolProperties.activeColor,
                            textBackgroundColor: _currentToolProperties.textBackgroundColor,
                            fillColor: _currentToolProperties.fillColor,
                            strokeWidth: _currentToolProperties.strokeWidth,
                            opacity: _currentToolProperties.opacity,
                            rotation: _rotation,
                            fontSize: _currentToolProperties.fontSize,
                            isFilled: _currentToolProperties.isFilled,
                            borderRadius: _currentToolProperties.borderRadius,
                            shapeKind: _currentToolProperties.shapeKind,
                            lineStyle: _currentToolProperties.lineStyle,
                            blurType: _currentToolProperties.blurType,
                            blurStrength: _currentToolProperties.blurStrength,
                            hasShadow: _currentToolProperties.hasShadow,
                            isDoubleArrow: _currentToolProperties.isDoubleArrow,
                            fillTolerance: _currentToolProperties.fillTolerance,
                            isGlobalFill: _currentToolProperties.isGlobalFill,
                            stepCounter: _stepCounter,
                            onAnnotationAdded: _onAnnotationAdded,
                            onAnnotationsUpdated: _onAnnotationsUpdated,
                            onAnnotationsLiveUpdated: _onAnnotationsLiveUpdated,
                            onStepCounterIncremented: (nextVal) => setState(() => _stepCounter = nextVal),
                            onApplyCrop: _handleApplyCrop,
                            onSampleColor: (color) {
                              _updateActiveToolProperty(activeColor: color);
                              _showToast(
                                'Sampled colour #${color.toARGB32().toRadixString(16).substring(2).toUpperCase()}',
                              );
                            },
                            // Snapshot the bitmap *before* the flood fill
                            // overwrites the file, otherwise undo would restore
                            // the already-filled image.
                            onBeforeCanvasFill: () => _pushUndoState(captureImage: true),
                            onImageSizeResolved: _handleImageSizeResolved,
                            onExtractText: _handleExtractText,
                            onPerformCanvasFill: (pos) {
                              setState(_bumpImageRevision);
                            },
                            // Cut, move and delete rewrite the file in place
                            // from inside the canvas, at the same path and the
                            // same size, so nothing else here would notice.
                            onImageBytesChanged: () {
                              setState(_bumpImageRevision);
                            },
                            // The canvas drops writes it cannot map into image
                            // pixels. Silently losing a stroke is its own bug,
                            // so say it out loud; the canvas throttles this so
                            // a drag cannot flood the toast.
                            onEditUnplaceable: () => _showToast(
                              'Could not apply that edit: the image has not '
                              'loaded. Try reselecting this capture.',
                            ),
                            repaintBoundaryKey: _repaintKey,
                            isDarkMode: _isDarkMode,
                            zoomScale: _zoomScale,
                            onZoomScaleChanged: (val) => setState(() => _zoomScale = val),
                            imageRevision: _imageRevision,
                          ),
                        ),

                        // Right Properties Sidebar Panel (Full Height & Collapsible Side Drawer)
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeInOut,
                          width: (_activeCapture != null && _isPropertiesOpen) ? 250 : 0,
                          height: double.infinity,
                          child: ClipRect(
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              physics: const NeverScrollableScrollPhysics(),
                              child: SizedBox(
                                width: 250,
                                height: double.infinity,
                                child: StylePicker(
                                  selectedColor: _currentToolProperties.activeColor,
                                  onColorChanged: (color) => _updateActiveToolProperty(activeColor: color),
                                  textBackgroundColor: _currentToolProperties.textBackgroundColor,
                                  onTextBackgroundColorChanged: (c) => _updateActiveToolProperty(textBackgroundColor: c),
                                  fillColor: _currentToolProperties.fillColor,
                                  onFillColorChanged: (c) => _updateActiveToolProperty(fillColor: c),
                                  shapeKind: _currentToolProperties.shapeKind,
                                  onShapeKindChanged: (k) => _updateActiveToolProperty(shapeKind: k),
                                  blurStrength: _currentToolProperties.blurStrength,
                                  onBlurStrengthChanged: (v) => _updateActiveToolProperty(blurStrength: v),
                                  hasShadow: _currentToolProperties.hasShadow,
                                  onShadowChanged: (v) => _updateActiveToolProperty(hasShadow: v),
                                  strokeWidth: _currentToolProperties.strokeWidth,
                                  onStrokeWidthChanged: (val) => _updateActiveToolProperty(strokeWidth: val),
                                  opacity: _currentToolProperties.opacity,
                                  onOpacityChanged: (val) => _updateActiveToolProperty(opacity: val),
                                  fontSize: _currentToolProperties.fontSize,
                                  onFontSizeChanged: (val) => _updateActiveToolProperty(fontSize: val),
                                  isFilled: _currentToolProperties.isFilled,
                                  onFillChanged: (val) => _updateActiveToolProperty(isFilled: val),
                                  rotation: _rotation,
                                  onRotationChanged: (r) => setState(() => _rotation = r),
                                  borderRadius: _currentToolProperties.borderRadius,
                                  onBorderRadiusChanged: (r) => _updateActiveToolProperty(borderRadius: r),
                                  lineStyle: _currentToolProperties.lineStyle,
                                  onLineStyleChanged: (s) => _updateActiveToolProperty(lineStyle: s),
                                  blurType: _currentToolProperties.blurType,
                                  onBlurTypeChanged: (b) => _updateActiveToolProperty(blurType: b),
                                  isDoubleArrow: _currentToolProperties.isDoubleArrow,
                                  onDoubleArrowChanged: (d) => _updateActiveToolProperty(isDoubleArrow: d),
                                  fillTolerance: _currentToolProperties.fillTolerance,
                                  onFillToleranceChanged: (t) => _updateActiveToolProperty(fillTolerance: t),
                                  isGlobalFill: _currentToolProperties.isGlobalFill,
                                  onGlobalFillChanged: (g) => _updateActiveToolProperty(isGlobalFill: g),
                                  activeTool: _activeTool,
                                  isDarkMode: _isDarkMode,
                                  stepCounter: _stepCounter,
                                  onResetStepCounter: () => setState(() => _stepCounter = 1),
                                  onRenumberSteps: _renumberStepMarkers,
                                  onActivateEyedropper: () => setState(() => _activeTool = CanvasTool.colorPicker),
                                  onFlattenCanvas: _annotations.isNotEmpty ? _handleFlattenCanvas : null,
                                  onCloseDrawer: () => setState(() => _isPropertiesOpen = false),
                                  selectedAnnotation: _selectedAnnotation,
                                  onDeleteSelected: _deleteSelectedAnnotation,
                                  onBringToFront: () => _reorderSelectedAnnotation(toFront: true),
                                  onSendToBack: () => _reorderSelectedAnnotation(toFront: false),
                                  onDeselect: () {
                                    setState(() {
                                      _selectedAnnotationId = null;
                                    });
                                  },
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),

                    // Floating Properties Drawer Open Pill Button (when drawer is collapsed)
                    if (_activeCapture != null && !_isPropertiesOpen)
                      Positioned(
                        top: 12,
                        right: 12,
                        child: Tooltip(
                          message: 'Show Tool Properties Drawer',
                          child: Material(
                            color: theme.surface,
                            elevation: 6,
                            borderRadius: BorderRadius.circular(20),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(20),
                              onTap: () => setState(() => _isPropertiesOpen = true),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(20),
                                  // CTA emphasis, not the exclusive active
                                  // control -- theme.emphasis, not activeFill.
                                  border: Border.all(color: theme.emphasis, width: 1.2),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.tune_rounded, size: 16, color: theme.emphasis),
                                    const SizedBox(width: 6),
                                    Text('Properties', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: theme.emphasis)),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),

                    // Extracted-text panel. Bottom-left keeps it clear of the
                    // properties drawer and its collapsed pill on the right.
                    if (_ocrResult != null)
                      Positioned(
                        left: 84,
                        bottom: 16,
                        child: OcrResultPanel(
                          result: _ocrResult!,
                          isLoading: _isOcrRunning,
                          unavailableReason: _ocrUnavailableReason,
                          isDarkMode: _isDarkMode,
                          onClose: () => setState(() {
                            _ocrRequestToken++;
                            _ocrResult = null;
                            _isOcrRunning = false;
                            _ocrUnavailableReason = null;
                          }),
                          onInsertAsText: _insertExtractedText,
                        ),
                      ),

                    // Capturing Overlay Spinner
                    //
                    // SnipTheme.scrim, not a per-mode token: this dims
                    // whatever was on screen the instant before a real
                    // OS-level capture, in both chrome modes, the same way a
                    // modal barrier would. A per-mode token would flip
                    // polarity in dark mode (a light wash instead of a dim)
                    // and risk the white spinner/caption vanishing against it
                    // — see SnipTheme.scrim's own doc comment.
                    if (_isCapturing)
                      Positioned.fill(
                        child: Container(
                          color: SnipTheme.scrim,
                          child: const Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CircularProgressIndicator(color: Colors.white),
                                SizedBox(height: 16),
                                Text(
                                  'Waiting for screen capture...',
                                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),

              // Bottom Gallery History Bar
              if (_isSidebarOpen)
                GallerySidebar(
                  items: _captures,
                  activeItem: _activeCapture,
                  isDarkMode: _isDarkMode,
                  zoomScale: _zoomScale,
                  onZoomScaleChanged: (val) => setState(() => _zoomScale = val),
                  onSelectItem: (item) {
                    _syncCurrentCaptureAnnotations();
                    setState(() {
                      // A different bitmap: nothing cached for the old one can
                      // describe it, and the open panel is about the old one.
                      _resetOcr();
                      _activeCapture = item;
                      _annotations = List.from(item.annotations);
                      _undoStack.clear();
                      _redoStack.clear();
                      _stepCounter = _findMaxStepNumber(item.annotations) + 1;
                    });
                    DatabaseService.setSetting('active_capture_id', item.id);
                    if (item.annotationsNeedConversion) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (!mounted) return;
                        _convertActiveCaptureAnnotations();
                      });
                    }
                  },
                  onDeleteItem: (item) async {
                    // Read before the setState below reassigns _activeCapture.
                    final wasActive = _activeCapture?.id == item.id;
                    if (wasActive) {
                      _syncCurrentCaptureAnnotations();
                    }
                    setState(() {
                      _captures.removeWhere((c) => c.id == item.id);
                      if (_activeCapture?.id == item.id) {
                        _resetOcr();
                        _activeCapture = _captures.isNotEmpty ? _captures.first : null;
                        _annotations = _activeCapture != null ? List.from(_activeCapture!.annotations) : [];
                        _undoStack.clear();
                        _redoStack.clear();
                        _stepCounter = _activeCapture != null ? _findMaxStepNumber(_annotations) + 1 : 1;
                      }
                    });
                    if (_activeCapture != null) {
                      DatabaseService.setSetting('active_capture_id', _activeCapture!.id);
                    }
                    // Deleting the active capture *promotes* the next one, which
                    // is a selection change by any other name — so it owes the
                    // same conversion onSelectItem schedules. Without this the
                    // promoted capture spends the session with viewport numbers
                    // treated as image pixels (markup at the wrong scale), and
                    // because the save guard correctly refuses to persist it,
                    // nothing the user draws on it is ever written.
                    //
                    // Gated on [wasActive] so deleting a *background* capture
                    // does not schedule a redundant second conversion for the
                    // unchanged active one — two in-flight runs could both pass
                    // the flag check across the decode await and double-scale.
                    if (wasActive &&
                        (_activeCapture?.annotationsNeedConversion ?? false)) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (!mounted) return;
                        _convertActiveCaptureAnnotations();
                      });
                    }
                    try {
                      final file = File(item.filePath);
                      if (file.existsSync()) {
                        await file.delete();
                      }
                    } catch (_) {}
                    StorageService.saveHistory(_captures);
                  },
                  onOpenLibraryLocation: () async {
                    final opened = await StorageService.openLibraryFolder();
                    if (!opened) {
                      _showToast('Could not open screenshots folder');
                    }
                  },
                  onRevealItemInFolder: (item) async {
                    final revealed = await StorageService.revealFileInFolder(item.filePath);
                    if (!revealed) {
                      _showToast('Could not reveal file in folder');
                    }
                  },
                  onClose: () => setState(() => _isSidebarOpen = false),
                ),
            ],
          ),
        ),
      ),
    )));
  }
}
