import 'package:flutter/material.dart';
import '../../models/app_shortcut.dart';
import '../../utils/constants.dart';

class HeaderBar extends StatelessWidget {
  final CanvasTool activeTool;
  final ValueChanged<CanvasTool> onToolSelected;
  final VoidCallback onSnipInteractive;
  final VoidCallback? onSnipFullScreen;
  final VoidCallback? onSnipTimer;
  final VoidCallback onImportImage;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onClear;
  final VoidCallback onCopyToClipboard;
  final VoidCallback onSaveAs;
  final VoidCallback? onFlattenCanvas;
  final VoidCallback onToggleSidebar;
  final VoidCallback onOpenShortcutSettings;
  final VoidCallback onToggleThemeMode;
  final VoidCallback onOpenAboutDialog;
  final bool canUndo;
  final bool canRedo;
  final VoidCallback? onToggleProperties;
  final bool isPropertiesOpen;
  final bool isSidebarOpen;
  final bool isDarkMode;
  final Map<AppShortcutAction, CustomShortcut>? shortcuts;
  final double zoomScale;
  final ValueChanged<double>? onZoomScaleChanged;

  const HeaderBar({
    super.key,
    required this.activeTool,
    required this.onToolSelected,
    required this.onSnipInteractive,
    this.onSnipFullScreen,
    this.onSnipTimer,
    required this.onImportImage,
    required this.onUndo,
    required this.onRedo,
    required this.onClear,
    required this.onCopyToClipboard,
    required this.onSaveAs,
    this.onFlattenCanvas,
    required this.onToggleSidebar,
    this.onToggleProperties,
    this.isPropertiesOpen = true,
    required this.onOpenShortcutSettings,
    required this.onToggleThemeMode,
    required this.onOpenAboutDialog,
    required this.canUndo,
    required this.canRedo,
    required this.isSidebarOpen,
    this.isDarkMode = true,
    this.shortcuts,
    this.zoomScale = 1.0,
    this.onZoomScaleChanged,
  });

  String _getShortcutText(AppShortcutAction action, String defaultText) {
    if (shortcuts != null && shortcuts!.containsKey(action)) {
      return shortcuts![action]!.toDisplayString();
    }
    return defaultText;
  }

  @override
  Widget build(BuildContext context) {
    final bgColor = isDarkMode ? AppColors.darkSurface : AppColors.lightSurface;
    final iconColor = isDarkMode ? Colors.white70 : Colors.black87;
    final borderColor = isDarkMode ? Colors.white10 : Colors.black12;

    return Container(
      height: 64,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(
          bottom: BorderSide(color: borderColor),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final content = Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Left: Logo, Capture, Export & History Actions (Left-Aligned Undo, Redo, Trash)
              Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.accent.withValues(alpha: 0.3),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.asset(
                        'assets/images/app_logo.png',
                        fit: BoxFit.cover,
                        errorBuilder: (ctx, err, stack) => Container(
                          color: AppColors.accent,
                          child: const Icon(Icons.camera_rounded, color: Colors.white, size: 20),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'SnipSnap',
                    style: TextStyle(
                      color: isDarkMode ? Colors.white : Colors.black87,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(width: 12),

                  // Pro Split Capture Button (Area Capture + Mode Dropdown)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: onSnipInteractive,
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(8),
                            bottomLeft: Radius.circular(8),
                          ),
                          child: Container(
                            height: 36,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: const BoxDecoration(
                              color: AppColors.accent,
                              borderRadius: BorderRadius.only(
                                topLeft: Radius.circular(8),
                                bottomLeft: Radius.circular(8),
                              ),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.crop_free_rounded, color: Colors.white, size: 16),
                                const SizedBox(width: 6),
                                const Text(
                                  'Snip',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Container(height: 36, width: 1, color: Colors.white24),
                      PopupMenuButton<String>(
                        tooltip: 'Capture Modes',
                        offset: const Offset(0, 42),
                        color: isDarkMode ? AppColors.darkSurfaceVariant : Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                          side: BorderSide(color: isDarkMode ? Colors.white12 : Colors.black12),
                        ),
                        onSelected: (val) {
                          if (val == 'area') {
                            onSnipInteractive();
                          } else if (val == 'full') {
                            onSnipFullScreen?.call();
                          } else if (val == 'timer') {
                            onSnipTimer?.call();
                          }
                        },
                        itemBuilder: (ctx) => [
                          PopupMenuItem(
                            value: 'area',
                            child: Row(
                              children: [
                                const Icon(Icons.crop_free_rounded, color: AppColors.accent, size: 18),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        'Capture Area',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 13,
                                          color: isDarkMode ? Colors.white : Colors.black87,
                                        ),
                                      ),
                                      Text(
                                        _getShortcutText(AppShortcutAction.interactiveSnip, 'Cmd+Shift+1'),
                                        style: const TextStyle(fontSize: 11, color: Colors.grey),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'full',
                            child: Row(
                              children: [
                                const Icon(Icons.fullscreen_rounded, color: AppColors.accent, size: 18),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        'Capture Full Screen',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 13,
                                          color: isDarkMode ? Colors.white : Colors.black87,
                                        ),
                                      ),
                                      Text(
                                        _getShortcutText(AppShortcutAction.fullScreenSnip, 'Cmd+Shift+2'),
                                        style: const TextStyle(fontSize: 11, color: Colors.grey),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'timer',
                            child: Row(
                              children: [
                                const Icon(Icons.timer_rounded, color: AppColors.accent, size: 18),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        'Timed Capture (3s)',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 13,
                                          color: isDarkMode ? Colors.white : Colors.black87,
                                        ),
                                      ),
                                      Text(
                                        _getShortcutText(AppShortcutAction.timerSnip, 'Cmd+Shift+5'),
                                        style: const TextStyle(fontSize: 11, color: Colors.grey),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        child: Container(
                          height: 36,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          decoration: const BoxDecoration(
                            color: AppColors.accent,
                            borderRadius: BorderRadius.only(
                              topRight: Radius.circular(8),
                              bottomRight: Radius.circular(8),
                            ),
                          ),
                          child: const Icon(Icons.arrow_drop_down_rounded, color: Colors.white, size: 20),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 6),
                  _HeaderButton(
                    icon: Icons.file_open_rounded,
                    label: 'Open',
                    tooltip: 'Open Image File (${_getShortcutText(AppShortcutAction.openImage, 'Cmd+O')})',
                    onPressed: onImportImage,
                    isDarkMode: isDarkMode,
                  ),

                  const SizedBox(width: 8),
                  Container(height: 24, width: 1, color: borderColor),
                  const SizedBox(width: 8),

                  // Export & Output Actions: Copy, Save As & Flatten
                  _HeaderButton(
                    icon: Icons.copy_rounded,
                    label: 'Copy',
                    tooltip: 'Copy Image to Clipboard (${_getShortcutText(AppShortcutAction.copyToClipboard, 'Cmd+C')})',
                    onPressed: onCopyToClipboard,
                    isDarkMode: isDarkMode,
                  ),
                  const SizedBox(width: 6),
                  _HeaderButton(
                    icon: Icons.download_rounded,
                    label: 'Save As',
                    tooltip: 'Save Image to Disk (${_getShortcutText(AppShortcutAction.saveAs, 'Cmd+S')})',
                    onPressed: onSaveAs,
                    isDarkMode: isDarkMode,
                  ),
                  if (onFlattenCanvas != null) ...[
                    const SizedBox(width: 6),
                    _HeaderButton(
                      icon: Icons.layers_clear_rounded,
                      label: 'Flatten',
                      tooltip: 'Bake Annotations into Image (${_getShortcutText(AppShortcutAction.flattenCanvas, 'Cmd+Shift+F')})',
                      onPressed: onFlattenCanvas!,
                      isDarkMode: isDarkMode,
                    ),
                  ],

                  const SizedBox(width: 8),
                  Container(height: 24, width: 1, color: borderColor),
                  const SizedBox(width: 8),

                  // LEFT-ALIGNED Edit & Undo/Redo/Trash Control Group
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    decoration: BoxDecoration(
                      color: isDarkMode ? AppColors.darkSurfaceVariant : AppColors.lightSurfaceVariant,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: borderColor),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.undo_rounded, size: 18),
                          color: canUndo ? (isDarkMode ? Colors.white : Colors.black87) : (isDarkMode ? Colors.white24 : Colors.black26),
                          tooltip: 'Undo (${_getShortcutText(AppShortcutAction.undo, 'Cmd+Z')})',
                          onPressed: canUndo ? onUndo : null,
                        ),
                        IconButton(
                          icon: const Icon(Icons.redo_rounded, size: 18),
                          color: canRedo ? (isDarkMode ? Colors.white : Colors.black87) : (isDarkMode ? Colors.white24 : Colors.black26),
                          tooltip: 'Redo (${_getShortcutText(AppShortcutAction.redo, 'Cmd+Shift+Z')})',
                          onPressed: canRedo ? onRedo : null,
                        ),
                        Container(height: 18, width: 1, color: borderColor),
                        IconButton(
                          icon: const Icon(Icons.delete_outline_rounded, size: 18),
                          color: iconColor,
                          tooltip: 'Clear Annotations (${_getShortcutText(AppShortcutAction.clearAnnotations, 'Cmd+Shift+K')})',
                          onPressed: onClear,
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              // Right: Slide to Zoom Control Bar + Preferences
              Row(
                children: [


                  // Hide/Show Right Tool Properties Drawer
                  if (onToggleProperties != null) ...[
                    IconButton(
                      icon: Icon(
                        isPropertiesOpen ? Icons.tune_rounded : Icons.tune_outlined,
                        color: isPropertiesOpen ? AppColors.accent : iconColor,
                        size: 20,
                      ),
                      tooltip: isPropertiesOpen ? 'Hide Tool Properties Drawer' : 'Show Tool Properties Drawer',
                      onPressed: onToggleProperties,
                    ),
                    const SizedBox(width: 2),
                  ],

                  // Keyboard Shortcut Settings
                  IconButton(
                    icon: Icon(Icons.keyboard_rounded, color: iconColor, size: 20),
                    tooltip: 'Configure Keyboard Shortcuts',
                    onPressed: onOpenShortcutSettings,
                  ),
                  const SizedBox(width: 2),

                  // Theme Mode Toggle (Light/Dark)
                  IconButton(
                    icon: Icon(
                      isDarkMode ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                      color: isDarkMode ? const Color(0xFFFFCC00) : const Color(0xFF5B21B6),
                      size: 20,
                    ),
                    tooltip: isDarkMode ? 'Switch to Light Mode' : 'Switch to Dark Mode',
                    onPressed: onToggleThemeMode,
                  ),
                  const SizedBox(width: 2),

                  // About SnipSnap Info Dialog
                  IconButton(
                    icon: Icon(Icons.info_outline_rounded, color: iconColor, size: 20),
                    tooltip: 'About SnipSnap',
                    onPressed: onOpenAboutDialog,
                  ),
                ],
              ),
            ],
          );

          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: content,
            ),
          );
        },
      ),
    );
  }
}

class _HeaderButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final String tooltip;
  final bool isDarkMode;

  const _HeaderButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    required this.tooltip,
    this.isDarkMode = true,
  });

  @override
  Widget build(BuildContext context) {
    final bgColor = isDarkMode ? AppColors.darkSurfaceVariant : AppColors.lightSurfaceVariant;
    final fgColor = isDarkMode ? Colors.white : Colors.black87;

    return Tooltip(
      message: tooltip,
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: bgColor,
          foregroundColor: fgColor,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        icon: Icon(icon, size: 15),
        label: Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        onPressed: onPressed,
      ),
    );
  }
}
