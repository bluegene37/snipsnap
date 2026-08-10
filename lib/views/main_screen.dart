import 'dart:io';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
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

  CanvasTool _activeTool = CanvasTool.pen;
  Color _activeColor = AppDefaults.defaultColor;
  double _strokeWidth = AppDefaults.defaultStrokeWidth;
  double _opacity = 1.0;
  double _fontSize = AppDefaults.defaultFontSize;
  bool _isFilled = false;
  int _stepCounter = 1;
  bool _isSidebarOpen = true;
  bool _isCapturing = false;
  bool _isDarkMode = true;

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

  Future<void> _loadHistory() async {
    final items = await StorageService.loadHistory();
    if (mounted) {
      setState(() {
        _captures.clear();
        _captures.addAll(items);
        if (_captures.isNotEmpty) {
          _activeCapture = _captures.first;
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
  }

  void _onAnnotationsUpdated(List<Annotation> updatedList) {
    _pushUndoState();
    setState(() {
      _annotations = List.from(updatedList);
    });
  }

  void _undo() {
    if (_undoStack.isNotEmpty) {
      _redoStack.add(List.from(_annotations));
      setState(() {
        _annotations = _undoStack.removeLast();
      });
    }
  }

  void _redo() {
    if (_redoStack.isNotEmpty) {
      _undoStack.add(List.from(_annotations));
      setState(() {
        _annotations = _redoStack.removeLast();
      });
    }
  }

  void _clearAnnotations() {
    if (_annotations.isNotEmpty) {
      _pushUndoState();
      setState(() {
        _annotations.clear();
      });
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
    ScaffoldMessenger.of(context).showSnackBar(
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
  }

  void _addCaptureFromPath(String path) {
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
    if (bytes != null) {
      final savedPath = await StorageService.exportImageDialog(bytes, _activeCapture!.title);
      if (savedPath != null) {
        _showToast('Saved screenshot to disk!');
      }
    }
  }

  void _showToast(String message) {
    final toastBg = _isDarkMode ? AppColors.darkSurfaceVariant : Colors.white;
    final textColor = _isDarkMode ? Colors.white : Colors.black87;
    final borderColor = _isDarkMode ? Colors.white12 : Colors.black12;

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
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
                onToggleSidebar: () => setState(() => _isSidebarOpen = !_isSidebarOpen),
                onOpenShortcutSettings: _openShortcutSettingsDialog,
                onToggleThemeMode: _toggleThemeMode,
                onOpenAboutDialog: _openAboutDialog,
                canUndo: _undoStack.isNotEmpty,
                canRedo: _redoStack.isNotEmpty,
                isSidebarOpen: _isSidebarOpen,
                isDarkMode: _isDarkMode,
                shortcuts: _shortcuts,
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
                          isDarkMode: _isDarkMode,
                        ),

                        // Editor Canvas
                        Expanded(
                          child: EditorCanvas(
                            imagePath: _activeCapture?.filePath,
                            annotations: _annotations,
                            activeTool: _activeTool,
                            activeColor: _activeColor,
                            strokeWidth: _strokeWidth,
                            opacity: _opacity,
                            fontSize: _fontSize,
                            isFilled: _isFilled,
                            stepCounter: _stepCounter,
                            onAnnotationAdded: _onAnnotationAdded,
                            onAnnotationsUpdated: _onAnnotationsUpdated,
                            onStepCounterIncremented: (nextVal) => setState(() => _stepCounter = nextVal),
                            repaintBoundaryKey: _repaintKey,
                            isDarkMode: _isDarkMode,
                          ),
                        ),

                        // Right Properties Sidebar Panel
                        if (_activeCapture != null)
                          StylePicker(
                            selectedColor: _activeColor,
                            onColorChanged: (color) => setState(() => _activeColor = color),
                            strokeWidth: _strokeWidth,
                            onStrokeWidthChanged: (val) => setState(() => _strokeWidth = val),
                            opacity: _opacity,
                            onOpacityChanged: (val) => setState(() => _opacity = val),
                            fontSize: _fontSize,
                            onFontSizeChanged: (val) => setState(() => _fontSize = val),
                            isFilled: _isFilled,
                            onFillChanged: (val) => setState(() => _isFilled = val),
                            activeTool: _activeTool,
                            isDarkMode: _isDarkMode,
                          ),
                      ],
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
                  onSelectItem: (item) {
                    setState(() {
                      _activeCapture = item;
                      _annotations.clear();
                      _undoStack.clear();
                      _redoStack.clear();
                      _stepCounter = 1;
                    });
                  },
                  onDeleteItem: (item) async {
            setState(() {
              _captures.removeWhere((c) => c.id == item.id);
              if (_activeCapture?.id == item.id) {
                _activeCapture = _captures.isNotEmpty ? _captures.first : null;
                _annotations.clear();
                _undoStack.clear();
                _redoStack.clear();
              }
            });
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
