import 'package:flutter/material.dart';
import '../../models/app_shortcut.dart';
import '../../utils/constants.dart';

/// Top application bar.
///
/// Laid out in three zones, following the convention used by Snagit, Shottr
/// and CleanShot:
///   * **Left**  — identity and *input*: capture modes and opening files.
///   * **Centre** — *editing*: undo/redo/clear and the zoom readout.
///   * **Right** — *output* (copy, save, flatten) then view and app settings.
///
/// Nothing is allowed to scroll out of reach: below [_compactBreakpoint] the
/// action buttons drop their text labels, and below [_iconOnlyBreakpoint] the
/// centre zone collapses so the export controls stay visible.
class HeaderBar extends StatelessWidget {
  static const double _compactBreakpoint = 1180;
  static const double _iconOnlyBreakpoint = 940;

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
  final bool canClear;
  final VoidCallback? onToggleProperties;
  final bool isPropertiesOpen;
  final bool isSidebarOpen;
  final bool isDarkMode;
  final bool hasCapture;
  final Map<AppShortcutAction, CustomShortcut>? shortcuts;
  final double zoomScale;
  final ValueChanged<double>? onZoomScaleChanged;

  const HeaderBar({
    super.key,
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
    this.canClear = false,
    required this.isSidebarOpen,
    this.isDarkMode = true,
    this.hasCapture = false,
    this.shortcuts,
    this.zoomScale = 1.0,
    this.onZoomScaleChanged,
  });

  String _shortcut(AppShortcutAction action, String fallback) {
    final custom = shortcuts?[action];
    return custom?.toDisplayString() ?? fallback;
  }

  @override
  Widget build(BuildContext context) {
    final bgColor = isDarkMode ? AppColors.darkSurface : AppColors.lightSurface;
    final borderColor = isDarkMode ? Colors.white10 : Colors.black12;

    return Container(
      height: 64,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final showLabels = constraints.maxWidth >= _compactBreakpoint;
          final showCentre = constraints.maxWidth >= _iconOnlyBreakpoint;

          return Row(
            children: [
              _buildBrand(),
              const SizedBox(width: 14),
              _buildCaptureGroup(showLabels),

              // Centre: editing controls, kept optically centred by the two
              // flexible gaps on either side.
              if (showCentre) ...[
                const Spacer(),
                _buildEditGroup(borderColor),
                if (onZoomScaleChanged != null && hasCapture) ...[
                  const SizedBox(width: 8),
                  _buildZoomGroup(borderColor),
                ],
                const Spacer(),
              ] else
                const Spacer(),

              _buildExportGroup(showLabels),
              const SizedBox(width: 10),
              _divider(borderColor),
              const SizedBox(width: 6),
              _buildViewGroup(),
              _buildOverflowMenu(),
            ],
          );
        },
      ),
    );
  }

  Widget _divider(Color color) => Container(height: 24, width: 1, color: color);

  Color get _iconColor => isDarkMode ? Colors.white70 : Colors.black87;

  // ---------------------------------------------------------------------------
  // Zones
  // ---------------------------------------------------------------------------

  Widget _buildBrand() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 30,
          height: 30,
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
                child: const Icon(Icons.camera_rounded, color: Colors.white, size: 18),
              ),
            ),
          ),
        ),
        const SizedBox(width: 9),
        Text(
          'SnipSnap',
          style: TextStyle(
            color: isDarkMode ? Colors.white : Colors.black87,
            fontSize: 17,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.4,
          ),
        ),
      ],
    );
  }

  /// Split button: the main half captures a region, the chevron picks a mode.
  Widget _buildCaptureGroup(bool showLabels) {
    return Row(
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
            child: Tooltip(
              message: 'Capture Area (${_shortcut(AppShortcutAction.interactiveSnip, 'Cmd+Shift+1')})',
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
                child: const Row(
                  children: [
                    Icon(Icons.crop_free_rounded, color: Colors.white, size: 16),
                    SizedBox(width: 6),
                    Text(
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
        ),
        Container(height: 36, width: 1, color: Colors.white24),
        PopupMenuButton<String>(
          tooltip: 'Capture Modes',
          position: PopupMenuPosition.under,
          color: isDarkMode ? AppColors.darkSurfaceVariant : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: isDarkMode ? Colors.white12 : Colors.black12),
          ),
          onSelected: (val) => switch (val) {
            'area' => onSnipInteractive(),
            'full' => onSnipFullScreen?.call(),
            'timer' => onSnipTimer?.call(),
            _ => null,
          },
          itemBuilder: (ctx) => [
            _captureMenuItem(
              value: 'area',
              icon: Icons.crop_free_rounded,
              title: 'Capture Area',
              subtitle: _shortcut(AppShortcutAction.interactiveSnip, 'Cmd+Shift+1'),
            ),
            _captureMenuItem(
              value: 'full',
              icon: Icons.fullscreen_rounded,
              title: 'Capture Full Screen',
              subtitle: _shortcut(AppShortcutAction.fullScreenSnip, 'Cmd+Shift+2'),
            ),
            _captureMenuItem(
              value: 'timer',
              icon: Icons.timer_rounded,
              title: 'Timed Capture (3s)',
              subtitle: _shortcut(AppShortcutAction.timerSnip, 'Cmd+Shift+5'),
            ),
          ],
          child: Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 4),
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
        const SizedBox(width: 6),
        _HeaderButton(
          icon: Icons.file_open_rounded,
          label: 'Open',
          showLabel: showLabels,
          tooltip: 'Open Image File (${_shortcut(AppShortcutAction.openImage, 'Cmd+O')})',
          onPressed: onImportImage,
          isDarkMode: isDarkMode,
        ),
      ],
    );
  }

  PopupMenuItem<String> _captureMenuItem({
    required String value,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(icon, color: AppColors.accent, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: isDarkMode ? Colors.white : Colors.black87,
                  ),
                ),
                Text(subtitle, style: const TextStyle(fontSize: 11, color: Colors.grey)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEditGroup(Color borderColor) {
    final enabledColor = isDarkMode ? Colors.white : Colors.black87;
    final disabledColor = isDarkMode ? Colors.white24 : Colors.black26;

    return _Pill(
      isDarkMode: isDarkMode,
      borderColor: borderColor,
      children: [
        _PillIconButton(
          icon: Icons.undo_rounded,
          tooltip: 'Undo (${_shortcut(AppShortcutAction.undo, 'Cmd+Z')})',
          color: canUndo ? enabledColor : disabledColor,
          onPressed: canUndo ? onUndo : null,
        ),
        _PillIconButton(
          icon: Icons.redo_rounded,
          tooltip: 'Redo (${_shortcut(AppShortcutAction.redo, 'Cmd+Shift+Z')})',
          color: canRedo ? enabledColor : disabledColor,
          onPressed: canRedo ? onRedo : null,
        ),
        Container(height: 18, width: 1, color: borderColor),
        _PillIconButton(
          icon: Icons.delete_outline_rounded,
          tooltip: 'Clear All Annotations '
              '(${_shortcut(AppShortcutAction.clearAnnotations, 'Cmd+Shift+K')})',
          color: canClear ? enabledColor : disabledColor,
          onPressed: canClear ? onClear : null,
        ),
      ],
    );
  }

  /// Compact zoom stepper. The gallery tray carries a full slider, but that
  /// tray can be hidden — zoom must stay reachable either way.
  Widget _buildZoomGroup(Color borderColor) {
    final enabledColor = isDarkMode ? Colors.white : Colors.black87;
    final disabledColor = isDarkMode ? Colors.white24 : Colors.black26;
    final canZoomOut = zoomScale > 0.2;
    final canZoomIn = zoomScale < 4.0;

    return _Pill(
      isDarkMode: isDarkMode,
      borderColor: borderColor,
      children: [
        _PillIconButton(
          icon: Icons.remove_rounded,
          tooltip: 'Zoom Out',
          color: canZoomOut ? enabledColor : disabledColor,
          onPressed:
              canZoomOut ? () => onZoomScaleChanged!((zoomScale - 0.25).clamp(0.2, 4.0)) : null,
        ),
        Tooltip(
          message: 'Reset Zoom to 100%',
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => onZoomScaleChanged!(1.0),
            child: Container(
              width: 46,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                '${(zoomScale * 100).round()}%',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.bold,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: (zoomScale - 1.0).abs() < 0.01 ? enabledColor : AppColors.accent,
                ),
              ),
            ),
          ),
        ),
        _PillIconButton(
          icon: Icons.add_rounded,
          tooltip: 'Zoom In',
          color: canZoomIn ? enabledColor : disabledColor,
          onPressed:
              canZoomIn ? () => onZoomScaleChanged!((zoomScale + 0.25).clamp(0.2, 4.0)) : null,
        ),
      ],
    );
  }

  Widget _buildExportGroup(bool showLabels) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _HeaderButton(
          icon: Icons.copy_rounded,
          label: 'Copy',
          showLabel: showLabels,
          tooltip: 'Copy Image to Clipboard '
              '(${_shortcut(AppShortcutAction.copyToClipboard, 'Cmd+C')})',
          onPressed: onCopyToClipboard,
          isDarkMode: isDarkMode,
          enabled: hasCapture,
        ),
        const SizedBox(width: 6),
        _HeaderButton(
          icon: Icons.download_rounded,
          label: 'Save As',
          showLabel: showLabels,
          tooltip: 'Save Image to Disk (${_shortcut(AppShortcutAction.saveAs, 'Cmd+S')})',
          onPressed: onSaveAs,
          isDarkMode: isDarkMode,
          enabled: hasCapture,
          isPrimary: true,
        ),
        const SizedBox(width: 6),
        _HeaderButton(
          icon: Icons.layers_clear_rounded,
          label: 'Flatten',
          showLabel: showLabels,
          tooltip: 'Bake Annotations into the Image '
              '(${_shortcut(AppShortcutAction.flattenCanvas, 'Cmd+Shift+F')})',
          onPressed: onFlattenCanvas ?? () {},
          isDarkMode: isDarkMode,
          enabled: onFlattenCanvas != null,
        ),
      ],
    );
  }

  Widget _buildViewGroup() {
    final borderColor = isDarkMode ? Colors.white10 : Colors.black12;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(
            isSidebarOpen ? Icons.photo_library_rounded : Icons.photo_library_outlined,
            size: 18,
          ),
          color: isSidebarOpen ? AppColors.accent : _iconColor,
          tooltip: isSidebarOpen
              ? 'Hide Screenshot Gallery (${_shortcut(AppShortcutAction.toggleHistory, 'Cmd+H')})'
              : 'Show Screenshot Gallery (${_shortcut(AppShortcutAction.toggleHistory, 'Cmd+H')})',
          style: IconButton.styleFrom(
            backgroundColor: isSidebarOpen
                ? AppColors.accent.withValues(alpha: 0.16)
                : (isDarkMode ? AppColors.darkSurfaceVariant : AppColors.lightSurfaceVariant),
            minimumSize: const Size(36, 36),
            padding: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: isSidebarOpen
                  ? const BorderSide(color: AppColors.accent, width: 1.2)
                  : BorderSide(color: borderColor),
            ),
          ),
          onPressed: onToggleSidebar,
        ),
        if (onToggleProperties != null) ...[
          const SizedBox(width: 6),
          IconButton(
            icon: Icon(
              isPropertiesOpen ? Icons.tune_rounded : Icons.tune_outlined,
              size: 18,
            ),
            color: isPropertiesOpen ? AppColors.accent : _iconColor,
            tooltip: isPropertiesOpen
                ? 'Hide Tool Properties'
                : 'Show Tool Properties',
            style: IconButton.styleFrom(
              backgroundColor: isPropertiesOpen
                  ? AppColors.accent.withValues(alpha: 0.16)
                  : (isDarkMode ? AppColors.darkSurfaceVariant : AppColors.lightSurfaceVariant),
              minimumSize: const Size(36, 36),
              padding: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: isPropertiesOpen
                    ? const BorderSide(color: AppColors.accent, width: 1.2)
                    : BorderSide(color: borderColor),
              ),
            ),
            onPressed: onToggleProperties,
          ),
        ],
      ],
    );
  }

  /// Low-frequency app settings live behind one menu so they never compete
  /// with the editing controls for space.
  Widget _buildOverflowMenu() {
    final borderColor = isDarkMode ? Colors.white10 : Colors.black12;
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: PopupMenuButton<String>(
        tooltip: 'More Options',
        position: PopupMenuPosition.under,
        color: isDarkMode ? AppColors.darkSurfaceVariant : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: isDarkMode ? Colors.white12 : Colors.black12),
        ),
        onSelected: (val) => switch (val) {
          'shortcuts' => onOpenShortcutSettings(),
          'theme' => onToggleThemeMode(),
          'about' => onOpenAboutDialog(),
          _ => null,
        },
        itemBuilder: (ctx) => [
          _overflowItem('shortcuts', Icons.keyboard_rounded, 'Keyboard Shortcuts…'),
          _overflowItem(
            'theme',
            isDarkMode ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
            isDarkMode ? 'Switch to Light Mode' : 'Switch to Dark Mode',
          ),
          _overflowItem('about', Icons.info_outline_rounded, 'About SnipSnap'),
        ],
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: isDarkMode ? AppColors.darkSurfaceVariant : AppColors.lightSurfaceVariant,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: borderColor),
          ),
          child: Icon(Icons.more_vert_rounded, color: _iconColor, size: 18),
        ),
      ),
    );
  }

  PopupMenuItem<String> _overflowItem(String value, IconData icon, String label) {
    return PopupMenuItem(
      value: value,
      height: 40,
      child: Row(
        children: [
          Icon(icon, size: 18, color: isDarkMode ? Colors.white70 : Colors.black87),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: isDarkMode ? Colors.white : Colors.black87,
            ),
          ),
        ],
      ),
    );
  }
}

/// Rounded container grouping related icon buttons.
class _Pill extends StatelessWidget {
  final List<Widget> children;
  final bool isDarkMode;
  final Color borderColor;

  const _Pill({
    required this.children,
    required this.isDarkMode,
    required this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      decoration: BoxDecoration(
        color: isDarkMode ? AppColors.darkSurfaceVariant : AppColors.lightSurfaceVariant,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

class _PillIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback? onPressed;

  const _PillIconButton({
    required this.icon,
    required this.tooltip,
    required this.color,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 17),
      color: color,
      // Disabled buttons must keep the explicit colour above, otherwise the
      // theme greys them a second time and they become nearly invisible.
      disabledColor: color,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 30),
      padding: EdgeInsets.zero,
      onPressed: onPressed,
    );
  }
}

class _HeaderButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final String tooltip;
  final bool isDarkMode;
  final bool showLabel;
  final bool enabled;
  final bool isPrimary;

  const _HeaderButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    required this.tooltip,
    this.isDarkMode = true,
    this.showLabel = true,
    this.enabled = true,
    this.isPrimary = false,
  });

  @override
  Widget build(BuildContext context) {
    final borderColor = isDarkMode ? Colors.white10 : Colors.black12;
    final bgColor = isPrimary
        ? AppColors.accent.withValues(alpha: 0.16)
        : (isDarkMode ? AppColors.darkSurfaceVariant : AppColors.lightSurfaceVariant);
    final fgColor = isPrimary
        ? AppColors.accent
        : (isDarkMode ? Colors.white : Colors.black87);

    final style = ElevatedButton.styleFrom(
      backgroundColor: bgColor,
      foregroundColor: fgColor,
      disabledBackgroundColor: bgColor.withValues(alpha: 0.35),
      disabledForegroundColor: isDarkMode ? Colors.white24 : Colors.black26,
      elevation: 0,
      padding: EdgeInsets.symmetric(horizontal: showLabel ? 12 : 9, vertical: 8),
      minimumSize: const Size(0, 36),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: isPrimary
            ? BorderSide(color: AppColors.accent.withValues(alpha: enabled ? 0.6 : 0.2), width: 1.2)
            : BorderSide(color: borderColor, width: 1.0),
      ),
    );

    return Tooltip(
      message: tooltip,
      child: showLabel
          ? ElevatedButton.icon(
              style: style,
              icon: Icon(icon, size: 15),
              label: Text(
                label,
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
              onPressed: enabled ? onPressed : null,
            )
          : ElevatedButton(
              style: style,
              onPressed: enabled ? onPressed : null,
              child: Icon(icon, size: 16),
            ),
    );
  }
}
