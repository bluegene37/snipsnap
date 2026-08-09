import 'package:flutter/material.dart';
import '../../utils/constants.dart';

class ToolBar extends StatelessWidget {
  final CanvasTool activeTool;
  final ValueChanged<CanvasTool> onToolSelected;
  final bool isDarkMode;

  const ToolBar({
    super.key,
    required this.activeTool,
    required this.onToolSelected,
    this.isDarkMode = true,
  });

  @override
  Widget build(BuildContext context) {
    final tools = [
      _ToolItem(CanvasTool.select, Icons.mouse_rounded, 'Select / Pan'),
      _ToolItem(CanvasTool.pen, Icons.edit_rounded, 'Freehand Pen'),
      _ToolItem(CanvasTool.arrow, Icons.north_east_rounded, 'Arrow'),
      _ToolItem(CanvasTool.line, Icons.horizontal_rule_rounded, 'Straight Line'),
      _ToolItem(CanvasTool.rectangle, Icons.crop_square_rounded, 'Rectangle'),
      _ToolItem(CanvasTool.oval, Icons.circle_outlined, 'Circle / Oval'),
      _ToolItem(CanvasTool.highlight, Icons.highlight_rounded, 'Highlighter'),
      _ToolItem(CanvasTool.stepMarker, Icons.looks_one_rounded, 'Step Badge (1, 2, 3)'),
      _ToolItem(CanvasTool.text, Icons.text_fields_rounded, 'Text Annotation'),
      _ToolItem(CanvasTool.blur, Icons.blur_on_rounded, 'Blur / Redact'),
      _ToolItem(CanvasTool.crop, Icons.crop_rounded, 'Crop Canvas'),
    ];

    final bgColor = isDarkMode ? AppColors.darkSurface : AppColors.lightSurface;
    final borderColor = isDarkMode ? Colors.white.withValues(alpha: 0.08) : Colors.black.withValues(alpha: 0.08);
    final iconColor = isDarkMode ? Colors.white70 : Colors.black87;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDarkMode ? 0.3 : 0.1),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(color: borderColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: tools.map((t) {
          final isSelected = activeTool == t.tool;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Tooltip(
              message: t.tooltip,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => onToolSelected(t.tool),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: isSelected ? AppColors.accent.withValues(alpha: 0.2) : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      border: isSelected
                          ? Border.all(color: AppColors.accent, width: 1.5)
                          : Border.all(color: Colors.transparent),
                    ),
                    child: Icon(
                      t.icon,
                      size: 20,
                      color: isSelected ? AppColors.accent : iconColor,
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _ToolItem {
  final CanvasTool tool;
  final IconData icon;
  final String tooltip;

  _ToolItem(this.tool, this.icon, this.tooltip);
}
