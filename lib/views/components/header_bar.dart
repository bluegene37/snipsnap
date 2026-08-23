import 'package:flutter/material.dart';
import '../../models/app_shortcut.dart';
import '../../utils/snip_theme.dart';

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
    final t = SnipTheme.of(context);

    return Container(
      height: 64,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final showLabels = constraints.maxWidth >= _compactBreakpoint;
          final showCentre = constraints.maxWidth >= _iconOnlyBreakpoint;
          final showBrandText = constraints.maxWidth >= 760;

          return Row(
            children: [
              _buildBrand(t, showText: showBrandText),
              SizedBox(width: showBrandText ? 14 : 8),
              _buildCaptureGroup(t, showLabels),

              // Centre: editing controls, kept optically centred by the two
              // flexible gaps on either side.
              if (showCentre) ...[
                const Spacer(),
                _buildEditGroup(t),
                if (onZoomScaleChanged != null && hasCapture) ...[
                  const SizedBox(width: 8),
                  _divider(t.border),
                  const SizedBox(width: 8),
                  _buildZoomGroup(t),
                ],
                const Spacer(),
              ] else
                const Spacer(),

              _buildViewGroup(t, showLabels),
              const SizedBox(width: 10),
              _divider(t.border),
              const SizedBox(width: 6),
              _buildExportGroup(t, showLabels),
              const SizedBox(width: 6),
              _HeaderButton(
                icon: t.isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                tooltip: t.isDark ? 'Switch to Light Mode' : 'Switch to Dark Mode',
                onPressed: onToggleThemeMode,
              ),
              const SizedBox(width: 6),
              _buildOverflowMenu(t),
            ],
          );
        },
      ),
    );
  }

  Widget _divider(Color color) => Container(height: 24, width: 1, color: color);

  // ---------------------------------------------------------------------------
  // Zones
  // ---------------------------------------------------------------------------

  Widget _buildBrand(SnipTheme t, {bool showText = true}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            boxShadow: const [
              BoxShadow(color: Colors.black38, blurRadius: 6, offset: Offset(0, 2)),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.asset(
              'assets/images/app_logo.png',
              fit: BoxFit.cover,
              errorBuilder: (ctx, err, stack) => ColoredBox(
                color: t.ink,
                child: Icon(Icons.camera_rounded, color: t.onActive, size: 18),
              ),
            ),
          ),
        ),
        if (showText) ...[
          const SizedBox(width: 9),
          Text(
            'SnipSnap',
            style: TextStyle(
              color: t.ink,
              fontSize: 17,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildCaptureGroup(SnipTheme t, bool showLabels) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          height: 36,
          decoration: BoxDecoration(
            color: t.surfaceRaised,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: t.emphasis, width: 1.2),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onSnipInteractive,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(7),
                    bottomLeft: Radius.circular(7),
                  ),
                  child: Tooltip(
                    message: 'Capture Area (${_shortcut(AppShortcutAction.interactiveSnip, 'Cmd+Shift+1')})',
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.crop_free_rounded, color: t.emphasis, size: 16),
                          const SizedBox(width: 6),
                          Text(
                            'Snip',
                            style: TextStyle(
                              color: t.emphasis,
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
              Container(height: 24, width: t.hairline, color: t.border),
              PopupMenuButton<String>(
                tooltip: 'Capture Modes',
                position: PopupMenuPosition.under,
                color: t.surfaceRaised,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(color: t.border),
                ),
                onSelected: (val) => switch (val) {
                  'area' => onSnipInteractive(),
                  'full' => onSnipFullScreen?.call(),
                  'timer' => onSnipTimer?.call(),
                  _ => null,
                },
                itemBuilder: (ctx) => [
                  _captureMenuItem(
                    t,
                    value: 'area',
                    icon: Icons.crop_free_rounded,
                    title: 'Capture Area',
                    subtitle: _shortcut(AppShortcutAction.interactiveSnip, 'Cmd+Shift+1'),
                  ),
                  _captureMenuItem(
                    t,
                    value: 'full',
                    icon: Icons.fullscreen_rounded,
                    title: 'Capture Full Screen',
                    subtitle: _shortcut(AppShortcutAction.fullScreenSnip, 'Cmd+Shift+2'),
                  ),
                  _captureMenuItem(
                    t,
                    value: 'timer',
                    icon: Icons.timer_rounded,
                    title: 'Timed Capture (3s)',
                    subtitle: _shortcut(AppShortcutAction.timerSnip, 'Cmd+Shift+5'),
                  ),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(Icons.arrow_drop_down_rounded, color: t.emphasis, size: 20),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 6),
        _HeaderButton(
          icon: Icons.file_open_rounded,
          label: 'Open',
          showLabel: showLabels,
          tooltip: 'Open Image File (${_shortcut(AppShortcutAction.openImage, 'Cmd+O')})',
          onPressed: onImportImage,
        ),
      ],
    );
  }

  PopupMenuItem<String> _captureMenuItem(
    SnipTheme t, {
    required String value,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(icon, color: t.ink, size: 18),
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
                    color: t.ink,
                  ),
                ),
                Text(subtitle, style: TextStyle(fontSize: 11, color: t.inkMuted)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEditGroup(SnipTheme t) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _HeaderButton(
          icon: Icons.undo_rounded,
          tooltip: 'Undo (${_shortcut(AppShortcutAction.undo, 'Cmd+Z')})',
          enabled: canUndo,
          onPressed: canUndo ? onUndo : null,
        ),
        const SizedBox(width: 6),
        _HeaderButton(
          icon: Icons.redo_rounded,
          tooltip: 'Redo (${_shortcut(AppShortcutAction.redo, 'Cmd+Shift+Z')})',
          enabled: canRedo,
          onPressed: canRedo ? onRedo : null,
        ),
        const SizedBox(width: 6),
        _HeaderButton(
          icon: Icons.delete_outline_rounded,
          tooltip: 'Clear All Annotations '
              '(${_shortcut(AppShortcutAction.clearAnnotations, 'Cmd+Shift+K')})',
          enabled: canClear,
          onPressed: canClear ? onClear : null,
        ),
      ],
    );
  }

  Widget _buildZoomGroup(SnipTheme t) {
    final canZoomOut = zoomScale > 0.2;
    final canZoomIn = zoomScale < 4.0;
    final isDefaultZoom = (zoomScale - 1.0).abs() < 0.01;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _HeaderButton(
          icon: Icons.remove_rounded,
          tooltip: 'Zoom Out',
          enabled: canZoomOut,
          onPressed:
              canZoomOut ? () => onZoomScaleChanged!((zoomScale - 0.25).clamp(0.2, 4.0)) : null,
        ),
        const SizedBox(width: 6),
        _HeaderButton(
          label: '${(zoomScale * 100).round()}%',
          isBold: !isDefaultZoom,
          tooltip: 'Reset Zoom to 100%',
          onPressed: () => onZoomScaleChanged!(1.0),
        ),
        const SizedBox(width: 6),
        _HeaderButton(
          icon: Icons.add_rounded,
          tooltip: 'Zoom In',
          enabled: canZoomIn,
          onPressed:
              canZoomIn ? () => onZoomScaleChanged!((zoomScale + 0.25).clamp(0.2, 4.0)) : null,
        ),
      ],
    );
  }

  Widget _buildExportGroup(SnipTheme t, bool showLabels) {
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
          enabled: hasCapture,
        ),
        const SizedBox(width: 6),
        _HeaderButton(
          icon: Icons.layers_clear_rounded,
          label: 'Flatten',
          showLabel: showLabels,
          tooltip: 'Bake Annotations into the Image '
              '(${_shortcut(AppShortcutAction.flattenCanvas, 'Cmd+Shift+F')})',
          onPressed: onFlattenCanvas,
          enabled: onFlattenCanvas != null,
        ),
        const SizedBox(width: 6),
        _HeaderButton(
          icon: Icons.download_rounded,
          label: 'Save As',
          showLabel: showLabels,
          tooltip: 'Save Image to Disk (${_shortcut(AppShortcutAction.saveAs, 'Cmd+S')})',
          onPressed: onSaveAs,
          enabled: hasCapture,
          isPrimary: true,
        ),
      ],
    );
  }

  Widget _buildViewGroup(SnipTheme t, bool showLabels) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _HeaderButton(
          icon: isSidebarOpen ? Icons.photo_library_rounded : Icons.photo_library_outlined,
          isActive: isSidebarOpen,
          tooltip: isSidebarOpen
              ? 'Hide Screenshot Gallery (${_shortcut(AppShortcutAction.toggleHistory, 'Cmd+H')})'
              : 'Show Screenshot Gallery (${_shortcut(AppShortcutAction.toggleHistory, 'Cmd+H')})',
          onPressed: onToggleSidebar,
        ),
        if (onToggleProperties != null) ...[
          const SizedBox(width: 6),
          _HeaderButton(
            icon: isPropertiesOpen ? Icons.tune_rounded : Icons.tune_outlined,
            isActive: isPropertiesOpen,
            tooltip: isPropertiesOpen ? 'Hide Tool Properties' : 'Show Tool Properties',
            onPressed: onToggleProperties,
          ),
        ],
      ],
    );
  }

  Widget _buildOverflowMenu(SnipTheme t) {
    return PopupMenuButton<String>(
      tooltip: 'More Options',
      position: PopupMenuPosition.under,
      color: t.surfaceRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: t.border),
      ),
      onSelected: (val) => switch (val) {
        'shortcuts' => onOpenShortcutSettings(),
        'theme' => onToggleThemeMode(),
        'about' => onOpenAboutDialog(),
        _ => null,
      },
      itemBuilder: (ctx) => [
        _overflowItem(t, 'shortcuts', Icons.keyboard_rounded, 'Keyboard Shortcuts…'),
        _overflowItem(
          t,
          'theme',
          t.isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
          t.isDark ? 'Switch to Light Mode' : 'Switch to Dark Mode',
        ),
        _overflowItem(t, 'about', Icons.info_outline_rounded, 'About SnipSnap'),
      ],
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: t.border),
        ),
        child: Icon(Icons.more_vert_rounded, color: t.ink, size: 18),
      ),
    );
  }

  PopupMenuItem<String> _overflowItem(SnipTheme t, String value, IconData icon, String label) {
    return PopupMenuItem(
      value: value,
      height: 40,
      child: Row(
        children: [
          Icon(icon, size: 18, color: t.ink),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: t.ink,
            ),
          ),
        ],
      ),
    );
  }
}

class _HeaderButton extends StatelessWidget {
  final IconData? icon;
  final String? label;
  final VoidCallback? onPressed;
  final String tooltip;
  final bool showLabel;
  final bool enabled;
  final bool isPrimary;
  final bool isActive;
  final bool isBold;

  const _HeaderButton({
    this.icon,
    this.label,
    required this.onPressed,
    required this.tooltip,
    this.showLabel = true,
    this.enabled = true,
    this.isPrimary = false,
    this.isActive = false,
    this.isBold = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = SnipTheme.of(context);

    final bgColor = WidgetStateProperty.resolveWith((states) {
      if (!enabled) return Colors.transparent;
      if (isActive) return t.selectedFill;
      if (isPrimary) return t.surfaceRaised;
      return Colors.transparent;
    });

    final fgColor = WidgetStateProperty.resolveWith((states) {
      if (!enabled) return t.inkFaint;
      if (isPrimary) return t.emphasis;
      return t.ink;
    });

    final border = WidgetStateProperty.resolveWith((states) {
      if (!enabled) return BorderSide(color: t.border, width: t.hairline);
      if (isPrimary) return BorderSide(color: t.emphasis, width: 1.2);
      if (isActive) return BorderSide(color: t.selectedFill, width: t.hairline);
      if (states.contains(WidgetState.hovered) || states.contains(WidgetState.pressed)) {
        return BorderSide(color: t.borderStrong, width: t.hairline);
      }
      return BorderSide(color: t.border, width: t.hairline);
    });

    final style = ElevatedButton.styleFrom(
      elevation: 0,
      padding: EdgeInsets.symmetric(
        horizontal: (showLabel && label != null) || icon == null ? 10 : 0,
        vertical: 8
      ),
      minimumSize: const Size(36, 36),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
      ),
    ).copyWith(
      backgroundColor: bgColor,
      foregroundColor: fgColor,
      side: border,
    );

    Widget child;
    if (icon != null && label != null && showLabel) {
      child = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15),
          const SizedBox(width: 6),
          Text(
            label!,
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
          ),
        ],
      );
    } else if (icon != null) {
      child = Icon(icon, size: 16);
    } else if (label != null) {
      child = Text(
        label!,
        style: TextStyle(
          fontSize: 12.0,
          fontWeight: isBold ? FontWeight.w800 : FontWeight.w500,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      );
    } else {
      child = const SizedBox.shrink();
    }

    return Tooltip(
      message: tooltip,
      child: ElevatedButton(
        style: style,
        onPressed: enabled ? onPressed : null,
        child: child,
      ),
    );
  }
}
