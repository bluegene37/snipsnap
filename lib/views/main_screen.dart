import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import '../models/annotation.dart';
import '../models/app_shortcut.dart';
import '../models/capture_item.dart';
import '../models/tool_properties.dart';
import '../services/capture_service.dart';
import '../services/clipboard_service.dart';
import '../services/database_service.dart';
import '../services/render_service.dart';
import '../services/shortcut_service.dart';
import '../services/storage_service.dart';
import '../utils/constants.dart';
import '../utils/image_operations.dart';
import 'components/header_bar.dart';
import 'components/style_picker.dart';
import 'components/tool_sidebar.dart';
import 'dialogs/about_dialog.dart';
import 'dialogs/save_as_dialog.dart';
import 'dialogs/shortcut_settings_dialog.dart';
import 'editor_canvas.dart';
import 'gallery_sidebar.dart';

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
  final List<CanvasSnapshot> _undoStack = [];
  final List<CanvasSnapshot> _redoStack = [];
  static const int _maxUndoSteps = 80;
  int _imageRevision = 0;

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
    return _toolPropertiesMap[targetTool] ?? const ToolProperties(activeColor: AppColors.accent);
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
      final currentProps =
          _toolPropertiesMap[targetTool] ?? const ToolProperties(activeColor: AppColors.accent);

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
      _annotations[idx] = _annotations[idx].copyWith(
        color: activeColor,
        strokeWidth: strokeWidth,
        opacity: opacity,
        fontSize: fontSize,
        fill: isFilled,
        backgroundColor: textBackgroundColor,
        fillColor: fillColor,
        borderRadius: borderRadius,
        shapeKind: shapeKind,
        lineStyle: lineStyle,
        blurType: blurType,
        blurStrength: blurStrength,
        hasShadow: hasShadow,
        isDoubleArrow: isDoubleArrow,
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
    if (pending != null) StorageService.saveCaptureItem(pending);
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
      if (pending != null) StorageService.saveCaptureItem(pending);
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
    }
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
      _imageRevision++;
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
      _addCaptureFromPath(path);
    }
  }

  Future<void> _handleFullScreenCapture() async {
    setState(() => _isCapturing = true);
    final path = await _captureService.captureFullScreen();
    setState(() => _isCapturing = false);
    if (path != null) {
      _addCaptureFromPath(path);
    }
  }

  Future<void> _handleTimerCapture() async {
    setState(() => _isCapturing = true);
    _scaffoldMessengerKey.currentState?.showSnackBar(
      const SnackBar(
        content: Text(
          'Capturing in 3 seconds... Prepare your screen!',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        duration: Duration(seconds: 3),
        backgroundColor: AppColors.accent,
      ),
    );
    final path = await _captureService.captureTimer(3);
    setState(() => _isCapturing = false);
    if (path != null) {
      _addCaptureFromPath(path);
    }
  }

  Future<void> _handleImportImage() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.image,
        dialogTitle: 'Select Image File',
      );
      if (result != null && result.files.single.path != null) {
        final path = await _captureService.importImage(result.files.single.path!);
        if (path != null) {
          _addCaptureFromPath(path);
        }
      }
    } catch (e) {
      debugPrint('SnipSnap import image error: $e');
      _showToast('Failed to pick image file: ${e.toString()}');
    }
  }

  void _addCaptureFromPath(String path) {
    _syncCurrentCaptureAnnotations();
    final newItem = CaptureItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      filePath: path,
      title: 'Snap ${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}:${DateTime.now().second.toString().padLeft(2, '0')}',
      createdAt: DateTime.now(),
    );

    setState(() {
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

  /// Size of the editor canvas the annotations were laid out against.
  Size get _canvasSize {
    final renderObj = _repaintKey.currentContext?.findRenderObject();
    if (renderObj is RenderBox && renderObj.hasSize) return renderObj.size;
    return Size.zero;
  }

  /// Renders the active capture with its annotations burned in, at the source
  /// image's native resolution and with no editor chrome.
  Future<Uint8List?> _renderAnnotatedBytes() async {
    final capture = _activeCapture;
    if (capture == null) return null;

    final bytes = await RenderService.renderFlattenedPng(
      imagePath: capture.filePath,
      annotations: _annotations,
      canvasSize: _canvasSize,
    );
    if (bytes != null) return bytes;

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

          final exportBytes = (options.framingPadding > 0 ||
                  options.cornerRadius > 0 ||
                  options.shadowBlur > 0 ||
                  gradient != null)
              ? await RenderService.renderFlattenedPng(
                  imagePath: _activeCapture!.filePath,
                  annotations: _annotations,
                  canvasSize: _canvasSize,
                  framingPadding: options.framingPadding,
                  cornerRadius: options.cornerRadius,
                  shadowBlur: options.shadowBlur,
                  framingGradient: gradient,
                ) ?? bytes
              : bytes;

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

    await _pushUndoState(captureImage: true);

    final bytes = await _renderAnnotatedBytes();
    if (bytes == null) {
      _showToast('Failed to flatten canvas');
      return;
    }

    await _replaceActiveImageBytes(bytes);

    setState(() {
      _imageRevision++;
      _annotations = [];
      _stepCounter = 1;
    });
    _syncCurrentCaptureAnnotations();

    _showToast('Canvas flattened! Annotations baked into image.');
  }

  Future<void> _handleApplyCrop(Rect cropRect) async {
    if (_activeCapture == null || !File(_activeCapture!.filePath).existsSync()) return;

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
      if (imageRect.isEmpty) return;

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
        _imageRevision++;
        _annotations = [];
        _selectedAnnotationId = null;
        _activeTool = CanvasTool.select;
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
    final toastBg = _isDarkMode ? AppColors.darkSurfaceVariant : Colors.white;
    final textColor = _isDarkMode ? Colors.white : Colors.black87;
    final borderColor = _isDarkMode ? Colors.white12 : Colors.black12;

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
    return MaterialApp(
      scaffoldMessengerKey: _scaffoldMessengerKey,
      title: 'SnipSnap - Screen Capture & Markup',
      debugShowCheckedModeBanner: false,
      theme: _isDarkMode
          ? ThemeData(
              brightness: Brightness.dark,
              scaffoldBackgroundColor: AppColors.canvasBg,
              colorScheme: const ColorScheme.dark(
                primary: AppColors.accent,
                surface: AppColors.darkSurface,
              ),
              textTheme: GoogleFonts.interTextTheme(
                ThemeData.dark().textTheme,
              ),
              useMaterial3: true,
            )
          : ThemeData(
              brightness: Brightness.light,
              scaffoldBackgroundColor: AppColors.canvasBgLight,
              colorScheme: const ColorScheme.light(
                primary: AppColors.accent,
                surface: AppColors.lightSurface,
              ),
              textTheme: GoogleFonts.interTextTheme(
                ThemeData.light().textTheme,
              ),
              useMaterial3: true,
            ),
      home: Scaffold(
        backgroundColor: _isDarkMode ? AppColors.canvasBg : AppColors.canvasBgLight,
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
                            onPerformCanvasFill: (pos) {
                              setState(() {
                                _imageRevision++;
                              });
                            },
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
                            color: _isDarkMode ? AppColors.darkSurface : AppColors.lightSurface,
                            elevation: 6,
                            borderRadius: BorderRadius.circular(20),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(20),
                              onTap: () => setState(() => _isPropertiesOpen = true),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: AppColors.accent, width: 1.2),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.tune_rounded, size: 16, color: AppColors.accent),
                                    SizedBox(width: 6),
                                    Text('Properties', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppColors.accent)),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),

                    // Capturing Overlay Spinner
                    if (_isCapturing)
                      Positioned.fill(
                        child: Container(
                          color: Colors.black54,
                          child: const Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CircularProgressIndicator(color: AppColors.accent),
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
                      _activeCapture = item;
                      _annotations = List.from(item.annotations);
                      _undoStack.clear();
                      _redoStack.clear();
                      _stepCounter = _findMaxStepNumber(item.annotations) + 1;
                    });
                    DatabaseService.setSetting('active_capture_id', item.id);
                  },
                  onDeleteItem: (item) async {
                    if (_activeCapture?.id == item.id) {
                      _syncCurrentCaptureAnnotations();
                    }
                    setState(() {
                      _captures.removeWhere((c) => c.id == item.id);
                      if (_activeCapture?.id == item.id) {
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
    ));
  }
}
