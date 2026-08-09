import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import '../../utils/constants.dart';

class StylePicker extends StatelessWidget {
  final Color selectedColor;
  final ValueChanged<Color> onColorChanged;
  final double strokeWidth;
  final ValueChanged<double> onStrokeWidthChanged;
  final double opacity;
  final ValueChanged<double> onOpacityChanged;
  final double fontSize;
  final ValueChanged<double> onFontSizeChanged;
  final bool isFilled;
  final ValueChanged<bool> onFillChanged;
  final CanvasTool activeTool;
  final bool isDarkMode;

  const StylePicker({
    super.key,
    required this.selectedColor,
    required this.onColorChanged,
    required this.strokeWidth,
    required this.onStrokeWidthChanged,
    required this.opacity,
    required this.onOpacityChanged,
    required this.fontSize,
    required this.onFontSizeChanged,
    required this.isFilled,
    required this.onFillChanged,
    required this.activeTool,
    this.isDarkMode = true,
  });

  void _showColorPickerDialog(BuildContext context) {
    final dialogBg = isDarkMode ? AppColors.darkSurface : AppColors.lightSurface;
    final textColor = isDarkMode ? Colors.white : Colors.black87;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: dialogBg,
        title: Text('Pick Custom Color', style: TextStyle(color: textColor)),
        content: SingleChildScrollView(
          child: ColorPicker(
            pickerColor: selectedColor,
            onColorChanged: onColorChanged,
            pickerAreaHeightPercent: 0.7,
          ),
        ),
        actions: [
          TextButton(
            child: const Text('Done', style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.bold)),
            onPressed: () => Navigator.of(ctx).pop(),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final showStroke = [
      CanvasTool.pen,
      CanvasTool.arrow,
      CanvasTool.line,
      CanvasTool.rectangle,
      CanvasTool.oval,
      CanvasTool.highlight
    ].contains(activeTool);

    final showFont = activeTool == CanvasTool.text;
    final showFill = [CanvasTool.rectangle, CanvasTool.oval].contains(activeTool);

    final bgColor = isDarkMode ? AppColors.darkSurface : AppColors.lightSurface;
    final textColor = isDarkMode ? Colors.white : Colors.black87;
    final subTextColor = isDarkMode ? Colors.white54 : Colors.black54;
    final borderColor = isDarkMode ? Colors.white10 : Colors.black12;
    final cardBg = isDarkMode ? AppColors.darkSurfaceVariant : AppColors.lightSurfaceVariant;

    return Container(
      width: 240,
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(
          left: BorderSide(color: borderColor),
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Sidebar Title Header
          Row(
            children: [
              const Icon(Icons.tune_rounded, color: AppColors.accent, size: 18),
              const SizedBox(width: 8),
              Text(
                'Tool Properties',
                style: TextStyle(
                  color: textColor,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Divider(color: borderColor, height: 1),
          const SizedBox(height: 16),

          // Selection Color Swatches Grid
          Text(
            'SELECTION COLOR',
            style: TextStyle(
              color: subTextColor,
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              ...AppColors.palette.map((color) {
                final isSelected = selectedColor.toARGB32() == color.toARGB32();
                return GestureDetector(
                  onTap: () => onColorChanged(color),
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isSelected ? (isDarkMode ? Colors.white : Colors.black87) : Colors.transparent,
                        width: 2.5,
                      ),
                      boxShadow: isSelected
                          ? [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 8)]
                          : [],
                    ),
                    child: isSelected
                        ? const Icon(Icons.check_rounded, size: 16, color: Colors.white)
                        : null,
                  ),
                );
              }),
              // Custom Color Button
              Tooltip(
                message: 'Custom Color Picker',
                child: GestureDetector(
                  onTap: () => _showColorPickerDialog(context),
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: cardBg,
                      shape: BoxShape.circle,
                      border: Border.all(color: borderColor),
                    ),
                    child: Icon(Icons.color_lens_rounded, size: 16, color: textColor),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // Stroke Width Slider
          if (showStroke) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'STROKE WIDTH',
                  style: TextStyle(
                    color: subTextColor,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: cardBg,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '${strokeWidth.toInt()} px',
                    style: TextStyle(color: textColor, fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            SliderTheme(
              data: SliderThemeData(
                activeTrackColor: AppColors.accent,
                inactiveTrackColor: borderColor,
                thumbColor: AppColors.accent,
                trackHeight: 3,
              ),
              child: Slider(
                value: strokeWidth,
                min: 1.0,
                max: 20.0,
                onChanged: onStrokeWidthChanged,
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Opacity Slider
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'OPACITY',
                style: TextStyle(
                  color: subTextColor,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '${(opacity * 100).toInt()}%',
                  style: TextStyle(color: textColor, fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SliderTheme(
            data: SliderThemeData(
              activeTrackColor: AppColors.accent,
              inactiveTrackColor: borderColor,
              thumbColor: AppColors.accent,
              trackHeight: 3,
            ),
            child: Slider(
              value: opacity,
              min: 0.1,
              max: 1.0,
              onChanged: onOpacityChanged,
            ),
          ),
          const SizedBox(height: 16),

          // Font Size Slider
          if (showFont) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'FONT SIZE',
                  style: TextStyle(
                    color: subTextColor,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: cardBg,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '${fontSize.toInt()} pt',
                    style: TextStyle(color: textColor, fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            SliderTheme(
              data: SliderThemeData(
                activeTrackColor: AppColors.accent,
                inactiveTrackColor: borderColor,
                thumbColor: AppColors.accent,
                trackHeight: 3,
              ),
              child: Slider(
                value: fontSize,
                min: 10.0,
                max: 60.0,
                onChanged: onFontSizeChanged,
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Fill Toggle Option
          if (showFill) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'SHAPE FILL',
                  style: TextStyle(
                    color: subTextColor,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                  ),
                ),
                Switch(
                  value: isFilled,
                  activeTrackColor: AppColors.accent,
                  onChanged: onFillChanged,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
