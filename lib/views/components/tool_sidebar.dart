import 'package:flutter/material.dart';
import '../../utils/constants.dart';

/// Small chevron on the Shape tool button that opens the shape chooser.
class _ShapeKindFlyout extends StatelessWidget {
  final ShapeKind selected;
  final ValueChanged<ShapeKind> onSelected;
  final bool isDarkMode;
  final Color color;

  const _ShapeKindFlyout({
    required this.selected,
    required this.onSelected,
    required this.isDarkMode,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<ShapeKind>(
      tooltip: 'Choose shape',
      initialValue: selected,
      position: PopupMenuPosition.under,
      padding: EdgeInsets.zero,
      splashRadius: 12,
      color: isDarkMode ? AppColors.darkSurfaceVariant : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: isDarkMode ? Colors.white12 : Colors.black12),
      ),
      onSelected: onSelected,
      itemBuilder: (ctx) => [
        for (final kind in ShapeKind.values)
          PopupMenuItem(
            value: kind,
            height: 38,
            child: Row(
              children: [
                Icon(
                  kind.icon,
                  size: 17,
                  color: kind == selected
                      ? AppColors.accent
                      : (isDarkMode ? Colors.white70 : Colors.black87),
                ),
                const SizedBox(width: 10),
                Text(
                  kind.label,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: kind == selected ? FontWeight.bold : FontWeight.w500,
                    color: kind == selected
                        ? AppColors.accent
                        : (isDarkMode ? Colors.white : Colors.black87),
                  ),
                ),
              ],
            ),
          ),
      ],
      child: Icon(Icons.arrow_drop_down_rounded, size: 15, color: color),
    );
  }
}

class ToolSidebarItem {
  final CanvasTool tool;
  final IconData icon;
  final String label;
  final String tooltip;

  const ToolSidebarItem(this.tool, this.icon, this.label, this.tooltip);
}

class ToolSidebar extends StatelessWidget {
  final CanvasTool activeTool;
  final ValueChanged<CanvasTool> onToolSelected;
  final ShapeKind shapeKind;
  final ValueChanged<ShapeKind>? onShapeKindSelected;
  final bool isSidebarOpen;
  final VoidCallback? onToggleSidebar;
  final bool isDarkMode;

  const ToolSidebar({
    super.key,
    required this.activeTool,
    required this.onToolSelected,
    this.shapeKind = ShapeKind.rectangle,
    this.onShapeKindSelected,
    this.isSidebarOpen = true,
    this.onToggleSidebar,
    this.isDarkMode = true,
  });

  static const tools = [
    ToolSidebarItem(CanvasTool.select, Icons.pan_tool_alt_rounded, 'Select', 'Select & move annotations  (V)'),
    ToolSidebarItem(CanvasTool.pen, Icons.edit_rounded, 'Pen', 'Freehand drawing pen  (P)'),
    ToolSidebarItem(CanvasTool.line, Icons.horizontal_rule_rounded, 'Line', 'Draw straight line  (L)'),
    ToolSidebarItem(CanvasTool.arrow, Icons.north_east_rounded, 'Arrow', 'Draw directional arrow  (A)'),
    // Shape is rendered separately so it can carry a shape-kind flyout.
    ToolSidebarItem(CanvasTool.shape, Icons.category_rounded, 'Shape', 'Rectangle, ellipse, star & more  (S)'),
    ToolSidebarItem(CanvasTool.highlight, Icons.brush_rounded, 'Highlight', 'Freehand highlighter brush  (H)'),
    ToolSidebarItem(CanvasTool.text, Icons.text_fields_rounded, 'Text', 'Add text annotation label  (T)'),
    ToolSidebarItem(CanvasTool.stepMarker, Icons.pin_drop_rounded, 'Step', 'Numbered step pins 1, 2, 3…  (N)'),
    ToolSidebarItem(CanvasTool.blur, Icons.blur_on_rounded, 'Blur', 'Obfuscate / blur sensitive area  (B)'),
    ToolSidebarItem(CanvasTool.ruler, Icons.straighten_rounded, 'Ruler', 'Measure pixel distance  (M)'),
    ToolSidebarItem(CanvasTool.fill, Icons.format_color_fill_rounded, 'Fill', 'Paint bucket fill shape or image  (G)'),
    ToolSidebarItem(CanvasTool.crop, Icons.crop_rounded, 'Crop', 'Crop canvas & image area  (C)'),
  ];

  @override
  Widget build(BuildContext context) {
    final bgColor = isDarkMode ? AppColors.darkSurface : AppColors.lightSurface;
    final iconColor = isDarkMode ? Colors.white70 : Colors.black87;
    final labelColor = isDarkMode ? Colors.white54 : Colors.black54;
    final borderColor = isDarkMode ? Colors.white10 : Colors.black12;

    return Container(
      width: 68,
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(
          right: BorderSide(color: borderColor),
        ),
      ),
      child: Column(
        children: [
          const SizedBox(height: 12),
          Expanded(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Column(
                  children: tools.map((t) {
                    final isSelected = activeTool == t.tool;
                    final isShape = t.tool == CanvasTool.shape;

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Tooltip(
                        message: isShape
                            ? '${shapeKind.label} — click to draw, use the ▾ corner to switch shape'
                            : t.tooltip,
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () => onToolSelected(t.tool),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              width: 56,
                              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? AppColors.accent.withValues(alpha: 0.18)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(10),
                                border: isSelected
                                    ? Border.all(color: AppColors.accent, width: 1.5)
                                    : Border.all(color: Colors.transparent, width: 1.5),
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  // The shape button previews the active shape
                                  // and exposes a corner flyout to change it.
                                  Stack(
                                    clipBehavior: Clip.none,
                                    children: [
                                      Icon(
                                        isShape ? shapeKind.icon : t.icon,
                                        size: 22,
                                        color: isSelected ? AppColors.accent : iconColor,
                                      ),
                                      if (isShape && onShapeKindSelected != null)
                                        Positioned(
                                          right: -9,
                                          bottom: -4,
                                          child: _ShapeKindFlyout(
                                            selected: shapeKind,
                                            isDarkMode: isDarkMode,
                                            onSelected: (kind) {
                                              onShapeKindSelected!(kind);
                                              onToolSelected(CanvasTool.shape);
                                            },
                                            color: isSelected ? AppColors.accent : iconColor,
                                          ),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    t.label,
                                    style: TextStyle(
                                      color: isSelected ? AppColors.accent : labelColor,
                                      fontSize: 10,
                                      fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                    ),
                                    textAlign: TextAlign.center,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
          if (onToggleSidebar != null) ...[
            Divider(height: 1, color: borderColor),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Tooltip(
                message: isSidebarOpen ? 'Hide Screenshots Gallery (Cmd+H)' : 'Show Screenshots Gallery (Cmd+H)',
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: onToggleSidebar,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: 56,
                      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                      decoration: BoxDecoration(
                        color: isSidebarOpen
                            ? AppColors.accent.withValues(alpha: 0.18)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                        border: isSidebarOpen
                            ? Border.all(color: AppColors.accent, width: 1.5)
                            : Border.all(color: Colors.transparent, width: 1.5),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            isSidebarOpen ? Icons.photo_library_rounded : Icons.photo_library_outlined,
                            size: 22,
                            color: isSidebarOpen ? AppColors.accent : iconColor,
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'Screenshots',
                            style: TextStyle(
                              color: isSidebarOpen ? AppColors.accent : labelColor,
                              fontSize: 9,
                              fontWeight: isSidebarOpen ? FontWeight.bold : FontWeight.w500,
                            ),
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}
