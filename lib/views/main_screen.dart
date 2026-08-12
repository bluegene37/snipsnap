import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import '../models/annotation.dart';
import '../models/app_shortcut.dart';
import '../models/capture_item.dart';
import '../services/capture_service.dart';
import '../services/clipboard_service.dart';
import '../services/database_service.dart';
import '../services/shortcut_service.dart';
import '../services/storage_service.dart';
import '../utils/constants.dart';
import 'components/header_bar.dart';
import 'components/style_picker.dart';
import 'components/tool_sidebar.dart';
import 'dialogs/about_dialog.dart';
import 'dialogs/save_as_dialog.dart';
import 'dialogs/shortcut_settings_dialog.dart';
import 'editor_canvas.dart';
import 'gallery_sidebar.dart';

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
  final List<List<Annotation>> _undoStack = [];
  final List<List<Annotation>> _redoStack = [];

  CanvasTool _activeTool = CanvasTool.select;
  Color _activeColor = AppDefaults.defaultColor;
  Color? _textBackgroundColor;
  double _strokeWidth = AppDefaults.defaultStrokeWidth;
  double _opacity = 1.0;
  double _fontSize = AppDefaults.defaultFontSize;
  bool _isFilled = false;
  double _rotation = 0.0;
  double _zoomScale = 1.0;
  int _stepCounter = 1;
  bool _isSidebarOpen = true;
  bool _isPropertiesOpen = true;
  bool _isCapturing = false;
  bool _isDarkMode = true;

  final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

  Map<AppShortcutAction, CustomShortcut> _shortcuts = ShortcutService.getDefaultShortcuts();

  @override
  void initState() {
    super.initState();
    _loadShortcuts();
    _loadHistory();
    _loadThemePreference();
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

  void _syncCurrentCaptureAnnotations() {
    if (_activeCapture != null) {
      final updatedItem = _activeCapture!.copyWith(annotations: List.from(_annotations));
      _activeCapture = updatedItem;

      final idx = _captures.indexWhere((c) => c.id == updatedItem.id);
      if (idx != -1) {
        _captures[idx] = updatedItem;
      }

      StorageService.saveCaptureItem(updatedItem);
    }
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

  void _pushUndoState() {
    _undoStack.add(List.from(_annotations));
    _redoStack.clear();
  }

  void _onAnnotationAdded(Annotation annotation) {
    _pushUndoState();
    setState(() {
      _annotations.add(annotation);
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

  /// Live update during drag/resize/rotate – no undo push (undo is pushed once at gesture start)
  void _onAnnotationsLiveUpdated(List<Annotation> updatedList) {
    setState(() {
      _annotations = List.from(updatedList);
    });
    _syncCurrentCaptureAnnotations();
  }

  void _undo() {
    if (_undoStack.isNotEmpty) {
      _redoStack.add(List.from(_annotations));
      setState(() {
        _annotations = _undoStack.removeLast();
      });
      _syncCurrentCaptureAnnotations();
    }
  }

  void _redo() {
    if (_redoStack.isNotEmpty) {
      _undoStack.add(List.from(_annotations));
      setState(() {
        _annotations = _redoStack.removeLast();
      });
      _syncCurrentCaptureAnnotations();
    }
  }

  void _clearAnnotations() {
    if (_annotations.isNotEmpty) {
      _pushUndoState();
      setState(() {
        _annotations.clear();
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
      _annotations.clear();
      _undoStack.clear();
      _redoStack.clear();
      _stepCounter = 1;
    });
    StorageService.saveHistory(_captures);
    DatabaseService.setSetting('active_capture_id', newItem.id);
  }

  // Export & Copy Render
  Future<Uint8List?> _renderAnnotatedBytes() async {
    try {
      final boundary = _repaintKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary != null) {
        final image = await boundary.toImage(pixelRatio: 2.0); // 2x Retina resolution
        final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
        if (byteData != null) {
          return byteData.buffer.asUint8List();
        }
      }
    } catch (_) {}

    // Fallback to source file bytes if repaint boundary is unavailable
    if (_activeCapture != null && File(_activeCapture!.filePath).existsSync()) {
      return await File(_activeCapture!.filePath).readAsBytes();
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
          final savedPath = await StorageService.exportImageDialogWithFormat(
            bytes: bytes,
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

  Future<void> _handleFlattenCanvas() async {
    if (_activeCapture == null) {
      _showToast('No screenshot to flatten!');
      return;
    }
    if (_annotations.isEmpty) {
      _showToast('No annotations to flatten!');
      return;
    }

    final bytes = await _renderAnnotatedBytes();
    if (bytes != null) {
      final targetPath = _activeCapture!.filePath;
      await File(targetPath).writeAsBytes(bytes);

      setState(() {
        _annotations.clear();
        _undoStack.clear();
        _redoStack.clear();
        _stepCounter = 1;
      });
      _syncCurrentCaptureAnnotations();

      _showToast('Canvas flattened! Annotations baked into image.');
    }
  }

  Future<void> _handleApplyCrop(Rect cropRect) async {
    if (_activeCapture == null || !File(_activeCapture!.filePath).existsSync()) return;

    try {
      final boundary = _repaintKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      final canvasSize = boundary?.size ?? Size.zero;

      final fileBytes = await File(_activeCapture!.filePath).readAsBytes();
      final decoded = img.decodeImage(fileBytes);
      if (decoded == null) return;

      double scaleX = 1.0;
      double scaleY = 1.0;
      if (canvasSize.width > 0 && canvasSize.height > 0) {
        scaleX = decoded.width / canvasSize.width;
        scaleY = decoded.height / canvasSize.height;
      }

      final cropX = (cropRect.left * scaleX).round();
      final cropY = (cropRect.top * scaleY).round();
      final cropW = math.max(1, (cropRect.width * scaleX).round());
      final cropH = math.max(1, (cropRect.height * scaleY).round());

      // Create new target image of requested crop dimensions with transparent background (numChannels: 4 RGBA)
      final targetImage = img.Image(
        width: cropW,
        height: cropH,
        numChannels: 4,
      );
      img.fill(targetImage, color: img.ColorRgba8(0, 0, 0, 0));

      // Composite original image onto transparent canvas at offset (-cropX, -cropY)
      final dstX = -cropX;
      final dstY = -cropY;

      img.compositeImage(
        targetImage,
        decoded,
        dstX: dstX,
        dstY: dstY,
      );

      final croppedBytes = Uint8List.fromList(img.encodePng(targetImage));

      final targetPath = _activeCapture!.filePath;
      await File(targetPath).writeAsBytes(croppedBytes);

      // Evict old cached image from memory so canvas updates immediately in real-time
      await FileImage(File(targetPath)).evict();
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();

      setState(() {
        _annotations.clear();
        _undoStack.clear();
        _redoStack.clear();
        _activeTool = CanvasTool.select;
      });
      _syncCurrentCaptureAnnotations();

      _showToast('Image cropped & canvas adjusted!');
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
                activeTool: _activeTool,
                onToolSelected: (tool) => setState(() => _activeTool = tool),
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
                              if (ann != null) {
                                setState(() {
                                  _activeColor = ann.color;
                                  _textBackgroundColor = ann.backgroundColor;
                                  _strokeWidth = ann.strokeWidth;
                                  _fontSize = ann.fontSize;
                                  _opacity = ann.opacity;
                                  _isFilled = ann.fill;
                                  _rotation = ann.rotation;
                                });
                              }
                            },
                            activeColor: _activeColor,
                            textBackgroundColor: _textBackgroundColor,
                            strokeWidth: _strokeWidth,
                            opacity: _opacity,
                            rotation: _rotation,
                            fontSize: _fontSize,
                            isFilled: _isFilled,
                            stepCounter: _stepCounter,
                            onAnnotationAdded: _onAnnotationAdded,
                            onAnnotationsUpdated: _onAnnotationsUpdated,
                            onAnnotationsLiveUpdated: _onAnnotationsLiveUpdated,
                            onStepCounterIncremented: (nextVal) => setState(() => _stepCounter = nextVal),
                            onApplyCrop: _handleApplyCrop,
                            repaintBoundaryKey: _repaintKey,
                            isDarkMode: _isDarkMode,
                            zoomScale: _zoomScale,
                            onZoomScaleChanged: (val) => setState(() => _zoomScale = val),
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
                                  selectedColor: _activeColor,
                                  onColorChanged: (color) => setState(() => _activeColor = color),
                                  textBackgroundColor: _textBackgroundColor,
                                  onTextBackgroundColorChanged: (c) => setState(() => _textBackgroundColor = c),
                                  strokeWidth: _strokeWidth,
                                  onStrokeWidthChanged: (val) => setState(() => _strokeWidth = val),
                                  opacity: _opacity,
                                  onOpacityChanged: (val) => setState(() => _opacity = val),
                                  fontSize: _fontSize,
                                  onFontSizeChanged: (val) => setState(() => _fontSize = val),
                                  isFilled: _isFilled,
                                  onFillChanged: (val) => setState(() => _isFilled = val),
                                  rotation: _rotation,
                                  onRotationChanged: (r) => setState(() => _rotation = r),
                                  activeTool: _activeTool,
                                  isDarkMode: _isDarkMode,
                                  onFlattenCanvas: _annotations.isNotEmpty ? _handleFlattenCanvas : null,
                                  onCloseDrawer: () => setState(() => _isPropertiesOpen = false),
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
                  onClose: () => setState(() => _isSidebarOpen = false),
                ),
            ],
          ),
        ),
      ),
    ));
  }
}
