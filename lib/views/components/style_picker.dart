import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import '../../utils/constants.dart';

class StylePicker extends StatelessWidget {
  final Color selectedColor;
  final ValueChanged<Color> onColorChanged;
  final Color? textBackgroundColor;
  final ValueChanged<Color?>? onTextBackgroundColorChanged;
  final double strokeWidth;
  final ValueChanged<double> onStrokeWidthChanged;
  final double opacity;
  final ValueChanged<double> onOpacityChanged;
  final double fontSize;
  final ValueChanged<double> onFontSizeChanged;
  final bool isFilled;
  final ValueChanged<bool> onFillChanged;
  final double rotation;
  final ValueChanged<double>? onRotationChanged;
  final CanvasTool activeTool;
  final bool isDarkMode;
  final VoidCallback? onFlattenCanvas;
  final VoidCallback? onCloseDrawer;
  final int stepCounter;
  final VoidCallback? onResetStepCounter;
  final VoidCallback? onActivateEyedropper;

  const StylePicker({
    super.key,
    required this.selectedColor,
    required this.onColorChanged,
    this.textBackgroundColor,
    this.onTextBackgroundColorChanged,
    required this.strokeWidth,
    required this.onStrokeWidthChanged,
    required this.opacity,
    required this.onOpacityChanged,
    required this.fontSize,
    required this.onFontSizeChanged,
    required this.isFilled,
    required this.onFillChanged,
    this.rotation = 0.0,
    this.onRotationChanged,
    required this.activeTool,
    this.isDarkMode = true,
    this.onFlattenCanvas,
    this.onCloseDrawer,
    this.stepCounter = 1,
    this.onResetStepCounter,
    this.onActivateEyedropper,
  });

  void _showColorPickerDialog(BuildContext context) {
    final dialogBg = isDarkMode ? AppColors.darkSurface : AppColors.lightSurface;
    final textColor = isDarkMode ? Colors.white : Colors.black87;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: dialogBg,
        title: Text('Pick Text/Stroke Color', style: TextStyle(color: textColor)),
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

  void _showBgColorPickerDialog(BuildContext context) {
    final dialogBg = isDarkMode ? AppColors.darkSurface : AppColors.lightSurface;
    final textColor = isDarkMode ? Colors.white : Colors.black87;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: dialogBg,
        title: Text('Pick Text Background Color', style: TextStyle(color: textColor)),
        content: SingleChildScrollView(
          child: ColorPicker(
            pickerColor: textBackgroundColor ?? Colors.black.withValues(alpha: 0.75),
            onColorChanged: (c) {
              onTextBackgroundColorChanged?.call(c);
              onFillChanged(true);
            },
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

    final showFont = activeTool == CanvasTool.text || activeTool == CanvasTool.stepMarker;
    final showFill = [CanvasTool.rectangle, CanvasTool.oval, CanvasTool.text].contains(activeTool);

    final bgColor = isDarkMode ? AppColors.darkSurface : AppColors.lightSurface;
    final textColor = isDarkMode ? Colors.white : Colors.black87;
    final subTextColor = isDarkMode ? Colors.white54 : Colors.black54;
    final borderColor = isDarkMode ? Colors.white10 : Colors.black12;
    final cardBg = isDarkMode ? AppColors.darkSurfaceVariant : AppColors.lightSurfaceVariant;

    return Container(
      width: 250,
      height: double.infinity,
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(
          left: BorderSide(color: borderColor),
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Sidebar Title Header with Close Drawer Button
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
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
                if (onCloseDrawer != null)
                  IconButton(
                    icon: Icon(Icons.chevron_right_rounded, color: subTextColor, size: 20),
                    tooltip: 'Hide Properties Drawer',
                    onPressed: onCloseDrawer,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Divider(color: borderColor, height: 1),
            const SizedBox(height: 16),

            // Dedicated Fill Tool Info Card
            if (activeTool == CanvasTool.fill) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.accent.withValues(alpha: 0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.format_color_fill_rounded, color: selectedColor, size: 22),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Paint Bucket Fill',
                            style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Click any shape or canvas region to flood-fill with the selected color below.',
                      style: TextStyle(color: subTextColor, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Dedicated Step Marker Info Card
            if (activeTool == CanvasTool.stepMarker) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.accent.withValues(alpha: 0.3)),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 28,
                          height: 28,
                          decoration: const BoxDecoration(
                            color: AppColors.accent,
                            shape: BoxShape.circle,
                          ),
                          child: Center(
                            child: Text(
                              '$stepCounter',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Next Step Badge',
                                style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 12),
                              ),
                              Text(
                                'Click canvas to place #$stepCounter',
                                style: TextStyle(color: subTextColor, fontSize: 10),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (stepCounter > 1 && onResetStepCounter != null) ...[
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.restart_alt_rounded, size: 14),
                          label: const Text('Reset to #1', style: TextStyle(fontSize: 11)),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.accent,
                            side: const BorderSide(color: AppColors.accent),
                            padding: const EdgeInsets.symmetric(vertical: 4),
                          ),
                          onPressed: onResetStepCounter,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Selection Color Swatches Grid
            Text(
              activeTool == CanvasTool.text
                  ? 'TEXT COLOR'
                  : (activeTool == CanvasTool.highlight ? 'HIGHLIGHTER TINT' : 'SELECTION COLOR'),
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
                ...(activeTool == CanvasTool.highlight
                        ? const [
                            Color(0xFFFDE047),
                            Color(0xFF34D399),
                            Color(0xFF22D3EE),
                            Color(0xFFF472B6),
                            Color(0xFFFB923C),
                            Color(0xFFC084FC),
                          ]
                        : AppColors.palette)
                    .map((color) {
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
                // Eyedropper Color Picker Tool
                if (onActivateEyedropper != null)
                  Tooltip(
                    message: 'Pick color from screen/image',
                    child: GestureDetector(
                      onTap: onActivateEyedropper,
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: AppColors.accent.withValues(alpha: 0.15),
                          shape: BoxShape.circle,
                          border: Border.all(color: AppColors.accent),
                        ),
                        child: const Icon(Icons.colorize_rounded, size: 16, color: AppColors.accent),
                      ),
                    ),
                  ),
              ],
            ),

            const SizedBox(height: 24),

            // Stroke Width Controls (Presets + Slider + Live Line Preview)
            if (showStroke) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'LINE THICKNESS',
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
              const SizedBox(height: 8),

              // Quick Preset Chips for Stroke Width
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _StrokePresetChip(
                    label: '2px',
                    width: AppDefaults.strokeWidthThin,
                    isSelected: (strokeWidth - AppDefaults.strokeWidthThin).abs() < 0.5,
                    onSelect: onStrokeWidthChanged,
                    cardBg: cardBg,
                    textColor: textColor,
                  ),
                  _StrokePresetChip(
                    label: '4px',
                    width: AppDefaults.strokeWidthMedium,
                    isSelected: (strokeWidth - AppDefaults.strokeWidthMedium).abs() < 0.5,
                    onSelect: onStrokeWidthChanged,
                    cardBg: cardBg,
                    textColor: textColor,
                  ),
                  _StrokePresetChip(
                    label: '8px',
                    width: AppDefaults.strokeWidthThick,
                    isSelected: (strokeWidth - AppDefaults.strokeWidthThick).abs() < 0.5,
                    onSelect: onStrokeWidthChanged,
                    cardBg: cardBg,
                    textColor: textColor,
                  ),
                  _StrokePresetChip(
                    label: '14px',
                    width: AppDefaults.strokeWidthHeavy,
                    isSelected: (strokeWidth - AppDefaults.strokeWidthHeavy).abs() < 0.5,
                    onSelect: onStrokeWidthChanged,
                    cardBg: cardBg,
                    textColor: textColor,
                  ),
                ],
              ),
              const SizedBox(height: 4),

              // Continuous Slider
              SliderTheme(
                data: SliderThemeData(
                  activeTrackColor: AppColors.accent,
                  inactiveTrackColor: borderColor,
                  thumbColor: AppColors.accent,
                  trackHeight: 3,
                ),
                child: Slider(
                  value: strokeWidth.clamp(1.0, 30.0),
                  min: 1.0,
                  max: 30.0,
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

            // Fill & Text Background Color Option
            if (showFill) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    activeTool == CanvasTool.text ? 'TEXT BACKGROUND BOX' : 'SHAPE FILL',
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
                    onChanged: (val) {
                      onFillChanged(val);
                      if (!val && onTextBackgroundColorChanged != null) {
                        onTextBackgroundColorChanged!(null);
                      }
                    },
                  ),
                ],
              ),

              // Text Background Color Palette Swatches (when activeTool is Text)
              if (activeTool == CanvasTool.text) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    // Transparent (Text-Only) Tile
                    Tooltip(
                      message: 'Transparent (Text Only)',
                      child: GestureDetector(
                        onTap: () {
                          onFillChanged(false);
                          onTextBackgroundColorChanged?.call(null);
                        },
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: cardBg,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: (!isFilled || textBackgroundColor == null) ? AppColors.accent : borderColor,
                              width: (!isFilled || textBackgroundColor == null) ? 2.5 : 1,
                            ),
                          ),
                          child: const Icon(Icons.block_rounded, size: 14, color: Colors.redAccent),
                        ),
                      ),
                    ),
                    // Preset Background Color Swatches
                    ...[
                      Colors.black.withValues(alpha: 0.75),
                      Colors.white.withValues(alpha: 0.9),
                      const Color(0xFFFFD700),
                      const Color(0xFFFF3B30),
                      const Color(0xFF8A2BE2),
                      const Color(0xFF007AFF),
                      const Color(0xFF34C759),
                    ].map((bgC) {
                      final isSelected = isFilled && textBackgroundColor?.toARGB32() == bgC.toARGB32();
                      return GestureDetector(
                        onTap: () {
                          onTextBackgroundColorChanged?.call(bgC);
                          onFillChanged(true);
                        },
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: bgC,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isSelected ? AppColors.accent : Colors.black26,
                              width: isSelected ? 2.5 : 1,
                            ),
                          ),
                          child: isSelected ? const Icon(Icons.check_rounded, size: 14, color: Colors.white) : null,
                        ),
                      );
                    }),
                    // Custom Text Background Color Picker
                    Tooltip(
                      message: 'Custom Text Background Color',
                      child: GestureDetector(
                        onTap: () => _showBgColorPickerDialog(context),
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: cardBg,
                            shape: BoxShape.circle,
                            border: Border.all(color: borderColor),
                          ),
                          child: Icon(Icons.color_lens_rounded, size: 14, color: textColor),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
            ],

            // Item Rotation Section (Angle Presets + Continuous Slider)
            if (onRotationChanged != null) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'ROTATION',
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
                      '${(rotation * 180 / 3.141592653589793).round()}°',
                      style: TextStyle(color: textColor, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  ...[-90, -45, 0, 45, 90, 180].map((deg) {
                    final rad = deg * 3.141592653589793 / 180;
                    final isSelected = ((rotation - rad).abs() < 0.05);
                    return GestureDetector(
                      onTap: () => onRotationChanged!(rad),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: isSelected ? AppColors.accent : cardBg,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: isSelected ? AppColors.accent : borderColor,
                          ),
                        ),
                        child: Text(
                          '$deg°',
                          style: TextStyle(
                            color: isSelected ? Colors.white : textColor,
                            fontSize: 10,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                          ),
                        ),
                      ),
                    );
                  }),
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
                  value: rotation.clamp(-3.141592653589793, 3.141592653589793),
                  min: -3.141592653589793,
                  max: 3.141592653589793,
                  onChanged: onRotationChanged,
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Flatten Canvas Action Button
            if (onFlattenCanvas != null) ...[
              Divider(color: borderColor),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: Tooltip(
                  message: 'Bake annotations into background image permanently',
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent.withValues(alpha: 0.15),
                      foregroundColor: AppColors.accent,
                      side: const BorderSide(color: AppColors.accent, width: 1.2),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    icon: const Icon(Icons.layers_clear_rounded, size: 16),
                    label: const Text(
                      'Flatten Canvas',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                    onPressed: onFlattenCanvas,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StrokePresetChip extends StatelessWidget {
  final String label;
  final double width;
  final bool isSelected;
  final ValueChanged<double> onSelect;
  final Color cardBg;
  final Color textColor;

  const _StrokePresetChip({
    required this.label,
    required this.width,
    required this.isSelected,
    required this.onSelect,
    required this.cardBg,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onSelect(width),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.accent : cardBg,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isSelected ? AppColors.accent : Colors.transparent,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : textColor,
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

