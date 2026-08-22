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
                  _buildZoomGroup(t),
                ],
                const Spacer(),
              ] else
                const Spacer(),

              _buildExportGroup(t, showLabels),
              const SizedBox(width: 10),
              _divider(t.border),
              const SizedBox(width: 6),
              _buildViewGroup(t),
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
            // A plain elevation shadow, not a theme role: like the rest of
            // the app's drop shadows (editor_canvas.dart, ocr_result_panel.dart)
            // this stays a literal dark value in both modes rather than
            // following ink's inversion — a "shadow" that turned white in
            // dark mode would read as a glow, not a shadow.
            boxShadow: const [
              BoxShadow(color: Colors.black38, blurRadius: 6, offset: Offset(0, 2)),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.asset(
              'assets/images/snipsnap_logo.png',
              fit: BoxFit.cover,
              errorBuilder: (ctx, err, stack) => Container(
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

  /// Split button: the main half captures a region, the chevron picks a mode.
  ///
  /// The header's primary call-to-action, not a toggle — [SnipTheme.emphasis]
  /// per the "CTA emphasis, not the active control" rule. Matches the
  /// treatment `main_screen.dart`'s floating Properties pill already
  /// established: [SnipTheme.emphasis] borrows ink's *strength* for a
  /// border/icon/text, it is never a fill — [SnipTheme.activeFill] stays
  /// reserved for the single exclusive active control (the selected tool).
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
    return _Pill(
      borderColor: t.border,
      fillColor: t.surfaceRaised,
      children: [
        _PillIconButton(
          icon: Icons.undo_rounded,
          tooltip: 'Undo (${_shortcut(AppShortcutAction.undo, 'Cmd+Z')})',
          color: canUndo ? t.ink : t.inkFaint,
          onPressed: canUndo ? onUndo : null,
        ),
        _PillIconButton(
          icon: Icons.redo_rounded,
          tooltip: 'Redo (${_shortcut(AppShortcutAction.redo, 'Cmd+Shift+Z')})',
          color: canRedo ? t.ink : t.inkFaint,
          onPressed: canRedo ? onRedo : null,
        ),
        Container(height: 18, width: 1, color: t.border),
        _PillIconButton(
          icon: Icons.delete_outline_rounded,
          tooltip: 'Clear All Annotations '
              '(${_shortcut(AppShortcutAction.clearAnnotations, 'Cmd+Shift+K')})',
          color: canClear ? t.ink : t.inkFaint,
          onPressed: canClear ? onClear : null,
        ),
      ],
    );
  }

  /// Compact zoom stepper. The gallery tray carries a full slider, but that
  /// tray can be hidden — zoom must stay reachable either way.
  Widget _buildZoomGroup(SnipTheme t) {
    final canZoomOut = zoomScale > 0.2;
    final canZoomIn = zoomScale < 4.0;
    final isDefaultZoom = (zoomScale - 1.0).abs() < 0.01;

    return _Pill(
      borderColor: t.border,
      fillColor: t.surfaceRaised,
      children: [
        _PillIconButton(
          icon: Icons.remove_rounded,
          tooltip: 'Zoom Out',
          color: canZoomOut ? t.ink : t.inkFaint,
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
                  // Colour cannot carry this signal — emphasis is defined
                  // equal to ink, so an ink-vs-emphasis branch would render
                  // identically in both states. Weight is the only lever
                  // skeleton has left for "this differs from default."
                  fontWeight: isDefaultZoom ? FontWeight.w500 : FontWeight.w800,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: t.ink,
                ),
              ),
            ),
          ),
        ),
        _PillIconButton(
          icon: Icons.add_rounded,
          tooltip: 'Zoom In',
          color: canZoomIn ? t.ink : t.inkFaint,
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
          icon: Icons.download_rounded,
          label: 'Save As',
          showLabel: showLabels,
          tooltip: 'Save Image to Disk (${_shortcut(AppShortcutAction.saveAs, 'Cmd+S')})',
          onPressed: onSaveAs,
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
          enabled: onFlattenCanvas != null,
        ),
      ],
    );
  }

  // Both toggles below are independently switchable — the gallery and the
  // properties drawer can be open at once, neither excludes the other — so
  // neither is the exclusive active control. selectedFill/ink, not
  // activeFill/onActive; see _ToggleIconButton.
  Widget _buildViewGroup(SnipTheme t) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ToggleIconButton(
          icon: isSidebarOpen ? Icons.photo_library_rounded : Icons.photo_library_outlined,
          active: isSidebarOpen,
          tooltip: isSidebarOpen
              ? 'Hide Screenshot Gallery (${_shortcut(AppShortcutAction.toggleHistory, 'Cmd+H')})'
              : 'Show Screenshot Gallery (${_shortcut(AppShortcutAction.toggleHistory, 'Cmd+H')})',
          onPressed: onToggleSidebar,
        ),
        if (onToggleProperties != null) ...[
          const SizedBox(width: 6),
          _ToggleIconButton(
            icon: isPropertiesOpen ? Icons.tune_rounded : Icons.tune_outlined,
            active: isPropertiesOpen,
            tooltip: isPropertiesOpen ? 'Hide Tool Properties' : 'Show Tool Properties',
            onPressed: onToggleProperties,
          ),
        ],
        const SizedBox(width: 6),
        _ToggleIconButton(
          icon: t.isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
          active: false,
          tooltip: t.isDark ? 'Switch to Light Mode' : 'Switch to Dark Mode',
          onPressed: onToggleThemeMode,
        ),
      ],
    );
  }

  /// Low-frequency app settings live behind one menu so they never compete
  /// with the editing controls for space.
  Widget _buildOverflowMenu(SnipTheme t) {
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: PopupMenuButton<String>(
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

/// Rounded container grouping related icon buttons.
class _Pill extends StatelessWidget {
  final List<Widget> children;
  final Color borderColor;
  final Color fillColor;

  const _Pill({
    required this.children,
    required this.borderColor,
    required this.fillColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      decoration: BoxDecoration(
        color: fillColor,
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

/// A view-toggle icon button: independently switchable, so it renders
/// through [SnipTheme.controlDecoration]/[SnipTheme.controlForeground] with
/// `exclusive: false` — a [SnipTheme.selectedFill] highlight with ordinary
/// [SnipTheme.ink] foreground when active, never the knocked-out
/// [SnipTheme.activeFill] plate that's reserved for the sidebar's single
/// selected tool. Shared by the gallery and properties toggles so the same
/// three-state shape isn't hand-duplicated per call site.
class _ToggleIconButton extends StatelessWidget {
  final IconData icon;
  final bool active;
  final String tooltip;
  final VoidCallback? onPressed;

  const _ToggleIconButton({
    required this.icon,
    required this.active,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final t = SnipTheme.of(context);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onPressed,
          child: Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: t.controlDecoration(active: active, exclusive: false, radius: 8),
            child: Icon(
              icon,
              size: 18,
              color: t.controlForeground(active: active, exclusive: false),
            ),
          ),
        ),
      ),
    );
  }
}

/// Bordered header action button: hairline outline at rest; when [isPrimary]
/// marks it as the zone's call to action, its border/icon/text step up to
/// [SnipTheme.emphasis] strength (never a fill — see [SnipTheme.emphasis]'s
/// doc comment, "a header CTA" is its own worked example).
class _HeaderButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final String tooltip;
  final bool showLabel;
  final bool enabled;
  final bool isPrimary;

  const _HeaderButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    required this.tooltip,
    this.showLabel = true,
    this.enabled = true,
    this.isPrimary = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = SnipTheme.of(context);

    // isPrimary borrows SnipTheme.emphasis for border/icon/text weight only
    // — never a fill. Matches main_screen.dart's floating Properties pill:
    // emphasis signals "more weight than a resting hairline," activeFill
    // stays reserved for the single exclusive active control.
    final bgColor = isPrimary ? t.surfaceRaised : Colors.transparent;
    final fgColor = isPrimary ? t.emphasis : (enabled ? t.ink : t.inkFaint);
    final borderColor = isPrimary ? t.emphasis : t.border;

    final style = ElevatedButton.styleFrom(
      backgroundColor: bgColor,
      foregroundColor: fgColor,
      disabledBackgroundColor: bgColor,
      disabledForegroundColor: t.inkFaint,
      elevation: 0,
      padding: EdgeInsets.symmetric(horizontal: showLabel ? 12 : 9, vertical: 8),
      minimumSize: const Size(0, 36),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: enabled ? borderColor : t.border,
          width: isPrimary ? 1.2 : t.hairline,
        ),
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
