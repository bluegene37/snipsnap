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
  final VoidCallback onToggleSidebar;
  final VoidCallback onOpenShortcutSettings;
  final VoidCallback onToggleThemeMode;
  final VoidCallback onOpenAboutDialog;
  final bool canUndo;
  final bool canRedo;
  final bool isSidebarOpen;
  final bool isDarkMode;
  final Map<AppShortcutAction, CustomShortcut>? shortcuts;

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
    required this.onToggleSidebar,
    required this.onOpenShortcutSettings,
    required this.onToggleThemeMode,
    required this.onOpenAboutDialog,
    required this.canUndo,
    required this.canRedo,
    required this.isSidebarOpen,
    this.isDarkMode = true,
    this.shortcuts,
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
              // Left: Branding Logo, History Toggle, File Open, Edit Actions (Undo, Redo, Clear), Export Actions (Copy, Save As) & Shortcuts
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

                  // History Gallery Toggle
                  IconButton(
                    icon: Icon(
                      isSidebarOpen ? Icons.menu_open_rounded : Icons.photo_library_rounded,
                      color: isSidebarOpen ? AppColors.accent : iconColor,
                    ),
                    tooltip: 'Toggle History Gallery (${_getShortcutText(AppShortcutAction.toggleHistory, 'Cmd+H')})',
                    onPressed: onToggleSidebar,
                  ),

                  const SizedBox(width: 4),

                  // Open Image File Button
                  _HeaderButton(
                    icon: Icons.file_open_rounded,
                    label: 'Open',
                    tooltip: 'Open Image File (${_getShortcutText(AppShortcutAction.openImage, 'Cmd+O')})',
                    onPressed: onImportImage,
                    isDarkMode: isDarkMode,
                  ),

                  const SizedBox(width: 8),
                  Container(height: 24, width: 1, color: borderColor),
                  const SizedBox(width: 4),

                  // Edit Actions: Undo, Redo & Clear
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
                  IconButton(
                    icon: const Icon(Icons.delete_outline_rounded, size: 18),
                    color: iconColor,
                    tooltip: 'Clear Annotations (${_getShortcutText(AppShortcutAction.clearAnnotations, 'Cmd+Shift+K')})',
                    onPressed: onClear,
                  ),

                  const SizedBox(width: 4),
                  Container(height: 24, width: 1, color: borderColor),
                  const SizedBox(width: 8),

                  // Export Actions: Copy & Save As
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

                  const SizedBox(width: 4),

                  // Keyboard Shortcut Settings
                  IconButton(
                    icon: Icon(Icons.keyboard_rounded, color: iconColor, size: 20),
                    tooltip: 'Configure Keyboard Shortcuts',
                    onPressed: onOpenShortcutSettings,
                  ),
                ],
              ),

              const SizedBox(width: 16),

              // Right: System Preferences (Theme & About)
              Row(
                children: [
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

                  // About Dialog
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
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        icon: Icon(icon, size: 15),
        label: Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        onPressed: onPressed,
      ),
    );
  }
}
