import 'package:flutter/material.dart';
import '../../utils/constants.dart';
import '../../utils/snip_theme.dart';

/// Small chevron on the Shape tool button that opens the shape chooser.
class _ShapeKindFlyout extends StatelessWidget {
  final ShapeKind selected;
  final ValueChanged<ShapeKind> onSelected;
  final Color color;

  const _ShapeKindFlyout({
    required this.selected,
    required this.onSelected,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final t = SnipTheme.of(context);
    return PopupMenuButton<ShapeKind>(
      tooltip: 'Choose shape',
      initialValue: selected,
      position: PopupMenuPosition.under,
      padding: EdgeInsets.zero,
      splashRadius: 12,
      color: t.surfaceRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: t.border),
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
                  color: kind == selected ? t.ink : t.inkMuted,
                ),
                const SizedBox(width: 10),
                Text(
                  kind.label,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: kind == selected ? FontWeight.bold : FontWeight.w500,
                    color: t.ink,
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
    ToolSidebarItem(CanvasTool.select, Icons.crop_free_rounded, 'Select', 'Select & Cut region / annotations  (S/V)'),
    ToolSidebarItem(CanvasTool.pen, Icons.edit_rounded, 'Pen', 'Freehand drawing pen  (P)'),
    ToolSidebarItem(CanvasTool.line, Icons.horizontal_rule_rounded, 'Line', 'Draw straight line  (L)'),
    ToolSidebarItem(CanvasTool.arrow, Icons.north_east_rounded, 'Arrow', 'Draw directional arrow  (A)'),
    // Shape is rendered separately so it can carry a shape-kind flyout.
    ToolSidebarItem(CanvasTool.shape, Icons.category_rounded, 'Shape', 'Rectangle, ellipse, star & more  (U)'),
    ToolSidebarItem(CanvasTool.highlight, Icons.brush_rounded, 'Highlight', 'Freehand highlighter brush  (H)'),
    ToolSidebarItem(CanvasTool.text, Icons.text_fields_rounded, 'Text', 'Add text annotation label  (T)'),
    ToolSidebarItem(CanvasTool.stepMarker, Icons.pin_drop_rounded, 'Step', 'Numbered step pins 1, 2, 3…  (N)'),
    ToolSidebarItem(CanvasTool.blur, Icons.blur_on_rounded, 'Blur', 'Obfuscate / blur sensitive area  (B)'),
    ToolSidebarItem(CanvasTool.ruler, Icons.straighten_rounded, 'Ruler', 'Measure pixel distance  (M)'),
    ToolSidebarItem(CanvasTool.fill, Icons.format_color_fill_rounded, 'Fill', 'Paint bucket fill (connected / global)  (G)'),
    ToolSidebarItem(CanvasTool.crop, Icons.crop_rounded, 'Crop', 'Crop & expand canvas bounds  (C)'),
    // Labelled "Extract", not "Text": the Text tool above already owns that
    // word, and two identically labelled buttons in a 56px column are
    // indistinguishable.
    ToolSidebarItem(CanvasTool.ocr, Icons.text_snippet_outlined, 'Extract', 'Extract text from the image — drag a region or click for the whole image  (E)'),
  ];

  @override
  Widget build(BuildContext context) {
    final t = SnipTheme.of(context);

    return Container(
      width: 68,
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(
          right: BorderSide(color: t.border),
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
                  children: tools.map((toolItem) {
                    final isSelected = activeTool == toolItem.tool;
                    final isShape = toolItem.tool == CanvasTool.shape;

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Tooltip(
                        message: isShape
                            ? '${shapeKind.label} — click to draw, use the ▾ corner to switch shape'
                            : toolItem.tooltip,
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(t.radius),
                            onTap: () => onToolSelected(toolItem.tool),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              width: 56,
                              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                              // The selected tool is the app's one exclusive
                              // active control — activeFill/onActive.
                              decoration: t.controlDecoration(active: isSelected),
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
                                        isShape ? shapeKind.icon : toolItem.icon,
                                        size: 22,
                                        color: t.controlForeground(active: isSelected),
                                      ),
                                      if (isShape && onShapeKindSelected != null)
                                        Positioned(
                                          right: -9,
                                          bottom: -4,
                                          child: _ShapeKindFlyout(
                                            selected: shapeKind,
                                            onSelected: (kind) {
                                              onShapeKindSelected!(kind);
                                              onToolSelected(CanvasTool.shape);
                                            },
                                            color: t.controlForeground(active: isSelected),
                                          ),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    toolItem.label,
                                    style: TextStyle(
                                      color: t.controlForeground(active: isSelected, dim: true),
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
            Divider(height: 1, color: t.border),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Tooltip(
                message: isSidebarOpen ? 'Hide Screenshots Gallery (Cmd+H)' : 'Show Screenshots Gallery (Cmd+H)',
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(t.radius),
                    onTap: onToggleSidebar,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: 56,
                      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                      // Independently toggleable — it can be open at the
                      // same time as any selected tool above, so it is not
                      // the exclusive active control: selectedFill/ink, not
                      // activeFill/onActive.
                      decoration: t.controlDecoration(active: isSidebarOpen, exclusive: false),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            isSidebarOpen ? Icons.photo_library_rounded : Icons.photo_library_outlined,
                            size: 22,
                            color: t.controlForeground(active: isSidebarOpen, exclusive: false),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'Screenshots',
                            style: TextStyle(
                              color: t.controlForeground(active: isSidebarOpen, exclusive: false, dim: true),
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
