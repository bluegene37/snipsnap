import 'package:flutter/material.dart';
import '../../utils/constants.dart';

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
  final bool isSidebarOpen;
  final VoidCallback? onToggleSidebar;
  final bool isDarkMode;

  const ToolSidebar({
    super.key,
    required this.activeTool,
    required this.onToolSelected,
    this.isSidebarOpen = true,
    this.onToggleSidebar,
    this.isDarkMode = true,
  });

  static const tools = [
    ToolSidebarItem(CanvasTool.select, Icons.pan_tool_alt_rounded, 'Select', 'Select & move annotations'),
    ToolSidebarItem(CanvasTool.pen, Icons.edit_rounded, 'Pen', 'Freehand drawing pen'),
    ToolSidebarItem(CanvasTool.line, Icons.horizontal_rule_rounded, 'Line', 'Draw straight line'),
    ToolSidebarItem(CanvasTool.arrow, Icons.north_east_rounded, 'Arrow', 'Draw directional arrow'),
    ToolSidebarItem(CanvasTool.rectangle, Icons.rectangle_outlined, 'Rectangle', 'Draw rectangle box'),
    ToolSidebarItem(CanvasTool.oval, Icons.circle_outlined, 'Oval', 'Draw circle or oval shape'),
    ToolSidebarItem(CanvasTool.highlight, Icons.brush_rounded, 'Highlight', 'Freehand highlighter brush'),
    ToolSidebarItem(CanvasTool.text, Icons.text_fields_rounded, 'Text', 'Add text annotation label'),
    ToolSidebarItem(CanvasTool.stepMarker, Icons.pin_drop_rounded, 'Step', 'Numbered step pins (1, 2, 3...)'),
    ToolSidebarItem(CanvasTool.blur, Icons.blur_on_rounded, 'Blur', 'Obfuscate / Blur sensitive area'),
    ToolSidebarItem(CanvasTool.crop, Icons.crop_rounded, 'Crop', 'Crop canvas & image area'),
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
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Tooltip(
                        message: t.tooltip,
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
                                  Icon(
                                    t.icon,
                                    size: 22,
                                    color: isSelected ? AppColors.accent : iconColor,
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
