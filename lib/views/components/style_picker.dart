import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import '../../models/annotation.dart';
import '../../utils/constants.dart';

class StylePicker extends StatelessWidget {
  final Color selectedColor;
  final ValueChanged<Color> onColorChanged;
  final Color? textBackgroundColor;
  final ValueChanged<Color?>? onTextBackgroundColorChanged;
  final Color? fillColor;
  final ValueChanged<Color?>? onFillColorChanged;
  final ShapeKind shapeKind;
  final ValueChanged<ShapeKind>? onShapeKindChanged;
  final double blurStrength;
  final ValueChanged<double>? onBlurStrengthChanged;
  final bool hasShadow;
  final ValueChanged<bool>? onShadowChanged;
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
  final VoidCallback? onRenumberSteps;
  final VoidCallback? onActivateEyedropper;
  final double borderRadius;
  final ValueChanged<double>? onBorderRadiusChanged;
  final LineStyle lineStyle;
  final ValueChanged<LineStyle>? onLineStyleChanged;
  final BlurType blurType;
  final ValueChanged<BlurType>? onBlurTypeChanged;
  final bool isDoubleArrow;
  final ValueChanged<bool>? onDoubleArrowChanged;
  final Annotation? selectedAnnotation;
  final VoidCallback? onDeleteSelected;
  final VoidCallback? onBringToFront;
  final VoidCallback? onSendToBack;
  final VoidCallback? onDeselect;

  final double fillTolerance;
  final ValueChanged<double>? onFillToleranceChanged;
  final bool isGlobalFill;
  final ValueChanged<bool>? onGlobalFillChanged;

  const StylePicker({
    super.key,
    required this.selectedColor,
    required this.onColorChanged,
    this.textBackgroundColor,
    this.onTextBackgroundColorChanged,
    this.fillColor,
    this.onFillColorChanged,
    this.shapeKind = ShapeKind.rectangle,
    this.onShapeKindChanged,
    this.blurStrength = 14.0,
    this.onBlurStrengthChanged,
    this.hasShadow = false,
    this.onShadowChanged,
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
    this.onRenumberSteps,
    this.onActivateEyedropper,
    this.borderRadius = 8.0,
    this.onBorderRadiusChanged,
    this.lineStyle = LineStyle.solid,
    this.onLineStyleChanged,
    this.blurType = BlurType.gaussian,
    this.onBlurTypeChanged,
    this.isDoubleArrow = false,
    this.onDoubleArrowChanged,
    this.selectedAnnotation,
    this.onDeleteSelected,
    this.onBringToFront,
    this.onSendToBack,
    this.onDeselect,
    this.fillTolerance = 15.0,
    this.onFillToleranceChanged,
    this.isGlobalFill = false,
    this.onGlobalFillChanged,
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
    final effectiveTool = selectedAnnotation?.tool ?? activeTool;
    final effectiveShapeKind = selectedAnnotation?.shapeKind ?? shapeKind;

    final showStroke = [
      CanvasTool.pen,
      CanvasTool.arrow,
      CanvasTool.line,
      CanvasTool.shape,
      CanvasTool.highlight,
      CanvasTool.ruler,
    ].contains(effectiveTool);

    final showFont = effectiveTool == CanvasTool.text || effectiveTool == CanvasTool.stepMarker;
    final showFill = [CanvasTool.shape, CanvasTool.text].contains(effectiveTool);

    // A drop shadow adds depth to vector annotations, text callouts and step markers over screenshots.
    final showShadow = [
      CanvasTool.pen,
      CanvasTool.arrow,
      CanvasTool.line,
      CanvasTool.shape,
      CanvasTool.text,
      CanvasTool.stepMarker,
    ].contains(effectiveTool);

    // Corner radius applies to rectangular shapes, speech bubbles, text background badges, and blur redaction boxes.
    final showCornerRadius = (effectiveTool == CanvasTool.shape &&
            (effectiveShapeKind == ShapeKind.rectangle ||
                effectiveShapeKind == ShapeKind.speechBubble)) ||
        (effectiveTool == CanvasTool.text && isFilled) ||
        (effectiveTool == CanvasTool.blur);

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
                    const Icon(Icons.palette_rounded, color: AppColors.accent, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      'Styles & Properties',
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
            const SizedBox(height: 14),

            // 1. QUICK STYLES HEADER (Snagit Style)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Quick Styles',
                  style: TextStyle(
                    color: textColor,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: cardBg,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: borderColor),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Theme: ',
                        style: TextStyle(color: subTextColor, fontSize: 11),
                      ),
                      Text(
                        'Basic',
                        style: TextStyle(color: textColor, fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(width: 2),
                      Icon(Icons.arrow_drop_down_rounded, size: 14, color: subTextColor),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // Quick Styles Grid for Fill Tool
            if (activeTool == CanvasTool.fill) ...[
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _CircleColorSwatch(
                    color: Colors.transparent, // Transparent Fill
                    isTransparent: true,
                    isSelected: opacity <= 0.05 || selectedColor.a == 0,
                    onTap: () {
                      onColorChanged(Colors.transparent);
                      onOpacityChanged(0.0);
                    },
                    isDarkMode: isDarkMode,
                    size: 32,
                  ),
                  _CircleColorSwatch(
                    color: const Color(0xFFEF4444), // Crimson Red
                    isSelected: selectedColor.toARGB32() == 0xFFEF4444 && opacity > 0.05,
                    onTap: () {
                      onColorChanged(const Color(0xFFEF4444));
                      onOpacityChanged(1.0);
                    },
                    isDarkMode: isDarkMode,
                    size: 32,
                  ),
                  _CircleColorSwatch(
                    color: const Color(0xFFF97316), // Orange
                    isSelected: selectedColor.toARGB32() == 0xFFF97316 && opacity > 0.05,
                    onTap: () {
                      onColorChanged(const Color(0xFFF97316));
                      onOpacityChanged(1.0);
                    },
                    isDarkMode: isDarkMode,
                    size: 32,
                  ),
                  _CircleColorSwatch(
                    color: const Color(0xFFF59E0B), // Amber
                    isSelected: selectedColor.toARGB32() == 0xFFF59E0B && opacity > 0.05,
                    onTap: () {
                      onColorChanged(const Color(0xFFF59E0B));
                      onOpacityChanged(1.0);
                    },
                    isDarkMode: isDarkMode,
                    size: 32,
                  ),
                  _CircleColorSwatch(
                    color: const Color(0xFF10B981), // Emerald Green
                    isSelected: selectedColor.toARGB32() == 0xFF10B981 && opacity > 0.05,
                    onTap: () {
                      onColorChanged(const Color(0xFF10B981));
                      onOpacityChanged(1.0);
                    },
                    isDarkMode: isDarkMode,
                    size: 32,
                  ),
                  _CircleColorSwatch(
                    color: const Color(0xFF06B6D4), // Cyan
                    isSelected: selectedColor.toARGB32() == 0xFF06B6D4 && opacity > 0.05,
                    onTap: () {
                      onColorChanged(const Color(0xFF06B6D4));
                      onOpacityChanged(1.0);
                    },
                    isDarkMode: isDarkMode,
                    size: 32,
                  ),
                  _CircleColorSwatch(
                    color: const Color(0xFF8B5CF6), // Purple
                    isSelected: selectedColor.toARGB32() == 0xFF8B5CF6 && opacity > 0.05,
                    onTap: () {
                      onColorChanged(const Color(0xFF8B5CF6));
                      onOpacityChanged(1.0);
                    },
                    isDarkMode: isDarkMode,
                    size: 32,
                  ),
                  _CircleColorSwatch(
                    color: const Color(0xFFEC4899), // Pink
                    isSelected: selectedColor.toARGB32() == 0xFFEC4899 && opacity > 0.05,
                    onTap: () {
                      onColorChanged(const Color(0xFFEC4899));
                      onOpacityChanged(1.0);
                    },
                    isDarkMode: isDarkMode,
                    size: 32,
                  ),
                  _CircleColorSwatch(
                    color: const Color(0xFFFFFFFF), // Pure White
                    isSelected: selectedColor.toARGB32() == 0xFFFFFFFF && opacity > 0.05,
                    onTap: () {
                      onColorChanged(const Color(0xFFFFFFFF));
                      onOpacityChanged(1.0);
                    },
                    isDarkMode: isDarkMode,
                    size: 32,
                  ),
                  _CircleColorSwatch(
                    color: const Color(0xFF64748B), // Slate Gray
                    isSelected: selectedColor.toARGB32() == 0xFF64748B && opacity > 0.05,
                    onTap: () {
                      onColorChanged(const Color(0xFF64748B));
                      onOpacityChanged(1.0);
                    },
                    isDarkMode: isDarkMode,
                    size: 32,
                  ),
                  _CircleColorSwatch(
                    color: const Color(0xFF000000), // Pure Black
                    isSelected: selectedColor.toARGB32() == 0xFF000000 && opacity > 0.05,
                    onTap: () {
                      onColorChanged(const Color(0xFF000000));
                      onOpacityChanged(1.0);
                    },
                    isDarkMode: isDarkMode,
                    size: 32,
                  ),
                ],
              ),
              const SizedBox(height: 18),
            ],

            // 2. TOOL PROPERTIES HEADER
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  selectedAnnotation != null ? 'Item Properties' : 'Tool Properties',
                  style: TextStyle(
                    color: textColor,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Tooltip(
                  message: 'Tool options & settings',
                  child: Icon(Icons.help_outline_rounded, size: 16, color: subTextColor),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Divider(color: borderColor, height: 1),
            const SizedBox(height: 14),

            // Selection Tool Info Card
            if (activeTool == CanvasTool.select && selectedAnnotation == null) ...[
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
                        const Icon(Icons.crop_free_rounded, color: AppColors.accent, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          'Selection (Cut & Move)',
                          style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 12),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '• Drag over the image to create a selection.\n• Drag inside the selection to cut and move it (leaves transparency behind).\n• Press Delete to erase selection to transparent.\n• Press Esc to deselect/commit.',
                      style: TextStyle(color: subTextColor, fontSize: 11, height: 1.4),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Crop Tool Info Card
            if (activeTool == CanvasTool.crop) ...[
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
                        const Icon(Icons.crop_rounded, color: AppColors.accent, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          'Crop & Canvas Bounds',
                          style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 12),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '• Drag handles inward to crop image.\n• Drag handles outward to expand canvas with transparent space.\n• Click "Apply Crop" to commit changes.',
                      style: TextStyle(color: subTextColor, fontSize: 11, height: 1.4),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Dedicated Fill Tool Properties Card
            if (activeTool == CanvasTool.fill) ...[
              // Eyedropper and Fill Color Buttons
              Row(
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        Text('Eyedropper', style: TextStyle(color: subTextColor, fontSize: 11, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 6),
                        InkWell(
                          onTap: onActivateEyedropper,
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            height: 42,
                            decoration: BoxDecoration(
                              color: cardBg,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: borderColor),
                            ),
                            child: Center(
                              child: Icon(Icons.colorize_rounded, color: textColor, size: 20),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      children: [
                        Text('Fill', style: TextStyle(color: subTextColor, fontSize: 11, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 6),
                        InkWell(
                          onTap: () => _showColorPickerDialog(context),
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            height: 42,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            decoration: BoxDecoration(
                              color: cardBg,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: borderColor),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Container(
                                  width: 22,
                                  height: 22,
                                  decoration: BoxDecoration(
                                    color: opacity > 0.05 ? selectedColor : Colors.transparent,
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(color: isDarkMode ? Colors.white30 : Colors.black26),
                                  ),
                                  child: opacity <= 0.05
                                      ? const ClipRRect(
                                          borderRadius: BorderRadius.all(Radius.circular(3)),
                                          child: _MiniCheckerboard(),
                                        )
                                      : null,
                                ),
                                const SizedBox(width: 4),
                                Icon(Icons.arrow_drop_down_rounded, color: subTextColor, size: 18),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Tolerance Slider
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Tolerance:', style: TextStyle(color: textColor, fontSize: 12, fontWeight: FontWeight.w600)),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: cardBg,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: borderColor),
                    ),
                    child: Text('${fillTolerance.toInt()}%', style: TextStyle(color: textColor, fontSize: 11, fontWeight: FontWeight.bold)),
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
                  value: fillTolerance.clamp(0.0, 100.0),
                  min: 0.0,
                  max: 100.0,
                  onChanged: onFillToleranceChanged,
                ),
              ),
              const SizedBox(height: 12),

              // Opacity Slider
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Opacity:', style: TextStyle(color: textColor, fontSize: 12, fontWeight: FontWeight.w600)),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: cardBg,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: borderColor),
                    ),
                    child: Text('${(opacity * 100).toInt()}%', style: TextStyle(color: textColor, fontSize: 11, fontWeight: FontWeight.bold)),
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
                  value: opacity.clamp(0.0, 1.0),
                  min: 0.0,
                  max: 1.0,
                  onChanged: onOpacityChanged,
                ),
              ),
              const SizedBox(height: 12),

              // Global Fill Checkbox
              InkWell(
                onTap: () => onGlobalFillChanged?.call(!isGlobalFill),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: Checkbox(
                          value: isGlobalFill,
                          onChanged: (val) => onGlobalFillChanged?.call(val ?? false),
                          activeColor: AppColors.accent,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Global Fill',
                        style: TextStyle(color: textColor, fontSize: 12, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
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
                    if ((stepCounter > 1 && onResetStepCounter != null) || onRenumberSteps != null) ...[
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          if (stepCounter > 1 && onResetStepCounter != null)
                            Expanded(
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.restart_alt_rounded, size: 14),
                                label: const Text('Reset #1', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: AppColors.accent,
                                  side: const BorderSide(color: AppColors.accent),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
                                ),
                                onPressed: onResetStepCounter,
                              ),
                            ),
                          if (stepCounter > 1 && onResetStepCounter != null && onRenumberSteps != null)
                            const SizedBox(width: 6),
                          if (onRenumberSteps != null)
                            Expanded(
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.format_list_numbered_rounded, size: 14),
                                label: const Text('Renumber', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: AppColors.accent,
                                  side: const BorderSide(color: AppColors.accent),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
                                ),
                                onPressed: onRenumberSteps,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Shape Chooser Grid (all outlines available to the Shape tool)
            if (effectiveTool == CanvasTool.shape && onShapeKindChanged != null) ...[
              Text(
                'SHAPE',
                style: TextStyle(
                  color: subTextColor,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: ShapeKind.values.map((kind) {
                  final isSelected = effectiveShapeKind == kind;
                  return Tooltip(
                    message: kind.label,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => onShapeKindChanged!(kind),
                        child: Container(
                          width: 46,
                          height: 42,
                          decoration: BoxDecoration(
                            color: isSelected
                                ? AppColors.accent.withValues(alpha: 0.18)
                                : cardBg,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: isSelected ? AppColors.accent : borderColor,
                              width: isSelected ? 1.8 : 1,
                            ),
                          ),
                          child: Icon(
                            kind.icon,
                            size: 20,
                            color: isSelected ? AppColors.accent : textColor,
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 20),
            ],

            // Selection Color Swatches Grid
            Text(
              activeTool == CanvasTool.text
                  ? 'TEXT COLOR'
                  : (activeTool == CanvasTool.highlight
                      ? 'HIGHLIGHTER TINT'
                      : (activeTool == CanvasTool.fill ? 'FILL COLOR' : 'SELECTION COLOR')),
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
                if (activeTool == CanvasTool.fill)
                  _CircleColorSwatch(
                    color: Colors.transparent,
                    isTransparent: true,
                    isSelected: opacity <= 0.05 || selectedColor.a == 0,
                    onTap: () {
                      onColorChanged(Colors.transparent);
                      onOpacityChanged(0.0);
                    },
                    isDarkMode: isDarkMode,
                    size: 30,
                  ),
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
                  final isSelected = selectedColor.toARGB32() == color.toARGB32() &&
                      (activeTool != CanvasTool.fill || opacity > 0.05);
                  return _CircleColorSwatch(
                    color: color,
                    isSelected: isSelected,
                    onTap: () {
                      onColorChanged(color);
                      if (activeTool == CanvasTool.fill && opacity <= 0.05) {
                        onOpacityChanged(1.0);
                      }
                    },
                    isDarkMode: isDarkMode,
                    size: 30,
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
                // Eyedropper Color Picker Tool (ONLY visible for Fill tool)
                if (activeTool == CanvasTool.fill && onActivateEyedropper != null)
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
                // Clamped like every other slider here: a stored value can sit
                // outside the range (an annotation saved by an older build, or
                // a scalar projected back from image pixels) and Slider asserts
                // rather than coercing.
                value: opacity.clamp(0.1, 1.0),
                min: 0.1,
                max: 1.0,
                onChanged: onOpacityChanged,
              ),
            ),
            // Corner Radius (rectangles & speech bubbles)
            if (showCornerRadius) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'CORNER RADIUS',
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
                      '${borderRadius.toInt()} px',
                      style: TextStyle(color: textColor, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _RadiusPresetChip(
                    label: '0px',
                    radius: 0.0,
                    isSelected: borderRadius == 0.0,
                    onSelect: (r) => onBorderRadiusChanged?.call(r),
                    cardBg: cardBg,
                    textColor: textColor,
                  ),
                  _RadiusPresetChip(
                    label: '8px',
                    radius: 8.0,
                    isSelected: borderRadius == 8.0,
                    onSelect: (r) => onBorderRadiusChanged?.call(r),
                    cardBg: cardBg,
                    textColor: textColor,
                  ),
                  _RadiusPresetChip(
                    label: '16px',
                    radius: 16.0,
                    isSelected: borderRadius == 16.0,
                    onSelect: (r) => onBorderRadiusChanged?.call(r),
                    cardBg: cardBg,
                    textColor: textColor,
                  ),
                  _RadiusPresetChip(
                    label: '24px',
                    radius: 24.0,
                    isSelected: borderRadius == 24.0,
                    onSelect: (r) => onBorderRadiusChanged?.call(r),
                    cardBg: cardBg,
                    textColor: textColor,
                  ),
                ],
              ),
              SliderTheme(
                data: SliderThemeData(
                  activeTrackColor: AppColors.accent,
                  inactiveTrackColor: borderColor,
                  thumbColor: AppColors.accent,
                  trackHeight: 3,
                ),
                child: Slider(
                  value: borderRadius.clamp(0.0, 30.0),
                  min: 0.0,
                  max: 30.0,
                  onChanged: (val) => onBorderRadiusChanged?.call(val),
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Line Style (Solid vs Dashed)
            if (effectiveTool == CanvasTool.line || effectiveTool == CanvasTool.arrow) ...[
              Text(
                'LINE STYLE',
                style: TextStyle(
                  color: subTextColor,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: FilterChip(
                      label: const Center(child: Text('Solid', style: TextStyle(fontSize: 11))),
                      selected: lineStyle == LineStyle.solid,
                      selectedColor: AppColors.accent.withValues(alpha: 0.3),
                      checkmarkColor: AppColors.accent,
                      onSelected: (selected) {
                        if (selected) onLineStyleChanged?.call(LineStyle.solid);
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilterChip(
                      label: const Center(child: Text('Dashed', style: TextStyle(fontSize: 11))),
                      selected: lineStyle == LineStyle.dashed,
                      selectedColor: AppColors.accent.withValues(alpha: 0.3),
                      checkmarkColor: AppColors.accent,
                      onSelected: (selected) {
                        if (selected) onLineStyleChanged?.call(LineStyle.dashed);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],

            // Double Arrowhead Switch
            if (effectiveTool == CanvasTool.arrow) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'DOUBLE ARROWHEAD',
                    style: TextStyle(
                      color: subTextColor,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.8,
                    ),
                  ),
                  Switch(
                    value: isDoubleArrow,
                    activeTrackColor: AppColors.accent,
                    onChanged: (val) => onDoubleArrowChanged?.call(val),
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],

            // Blur Mode (Gaussian Blur vs Pixelate Mosaic vs Solid Blackout)
            if (effectiveTool == CanvasTool.blur) ...[
              Text(
                'REDACTION MODE',
                style: TextStyle(
                  color: subTextColor,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: FilterChip(
                      label: const Center(child: Text('Blur', style: TextStyle(fontSize: 10.5))),
                      selected: blurType == BlurType.gaussian,
                      selectedColor: AppColors.accent.withValues(alpha: 0.3),
                      checkmarkColor: AppColors.accent,
                      onSelected: (selected) {
                        if (selected) onBlurTypeChanged?.call(BlurType.gaussian);
                      },
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: FilterChip(
                      label: const Center(child: Text('Pixelate', style: TextStyle(fontSize: 10.5))),
                      selected: blurType == BlurType.pixelate,
                      selectedColor: AppColors.accent.withValues(alpha: 0.3),
                      checkmarkColor: AppColors.accent,
                      onSelected: (selected) {
                        if (selected) onBlurTypeChanged?.call(BlurType.pixelate);
                      },
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: FilterChip(
                      label: const Center(child: Text('Blackout', style: TextStyle(fontSize: 10.5))),
                      selected: blurType == BlurType.solid,
                      selectedColor: AppColors.accent.withValues(alpha: 0.3),
                      checkmarkColor: AppColors.accent,
                      onSelected: (selected) {
                        if (selected) onBlurTypeChanged?.call(BlurType.solid);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              if (blurType != BlurType.solid) ...[
                // Obscuration strength: gaussian sigma, or mosaic block size.
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      blurType == BlurType.pixelate ? 'BLOCK SIZE' : 'BLUR STRENGTH',
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
                        '${blurStrength.toInt()} px',
                        style: TextStyle(color: textColor, fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                SliderTheme(
                  data: SliderThemeData(
                    activeTrackColor: AppColors.accent,
                    inactiveTrackColor: borderColor,
                    thumbColor: AppColors.accent,
                    trackHeight: 3,
                  ),
                  child: Slider(
                    value: blurStrength.clamp(2.0, 50.0),
                    min: 2.0,
                    max: 50.0,
                    onChanged: (v) => onBlurStrengthChanged?.call(v),
                  ),
                ),
              ],
              Text(
                blurType == BlurType.solid
                    ? 'Solid blackout permanently covers sensitive passwords, API keys, or PII.'
                    : (blurType == BlurType.pixelate
                        ? 'Mosaic blocks fully discard the original pixels — safe for redacting data.'
                        : 'Gaussian blur softens the region; use a high strength for sensitive content.'),
                style: TextStyle(color: subTextColor, fontSize: 10.5, height: 1.3),
              ),
              const SizedBox(height: 16),
            ],

            // Drop Shadow Toggle
            if (showShadow && onShadowChanged != null) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'DROP SHADOW',
                    style: TextStyle(
                      color: subTextColor,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.8,
                    ),
                  ),
                  Switch(
                    value: hasShadow,
                    activeTrackColor: AppColors.accent,
                    onChanged: (val) => onShadowChanged!(val),
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],

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
                  // Canvas-space font size is `stored / scale`, so shrinking
                  // the window and selecting a text annotation can land below
                  // 10 — which is a Slider assertion (red screen in debug),
                  // not a clamp. Same treatment as stroke width and radius.
                  value: fontSize.clamp(10.0, 60.0),
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
                    effectiveTool == CanvasTool.text ? 'TEXT BACKGROUND BOX' : 'SHAPE FILL',
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
                        onTextBackgroundColorChanged!(Colors.transparent);
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Text Background Color Palette Swatches (when effectiveTool is Text)
              if (effectiveTool == CanvasTool.text) ...[
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

              // Independent shape fill colour — the outline keeps using the
              // selection colour above, as in Snagit's shape styles.
              if (isFilled && onFillColorChanged != null && effectiveTool == CanvasTool.shape) ...[
                const SizedBox(height: 4),
                Text(
                  'FILL COLOUR',
                  style: TextStyle(
                    color: subTextColor,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Tooltip(
                      message: 'Auto — 25% tint of the outline colour',
                      child: GestureDetector(
                        onTap: () => onFillColorChanged!(null),
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: selectedColor.withValues(alpha: 0.25),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: fillColor == null ? AppColors.accent : borderColor,
                              width: fillColor == null ? 2.5 : 1,
                            ),
                          ),
                          child: Icon(Icons.auto_awesome_rounded, size: 13, color: textColor),
                        ),
                      ),
                    ),
                    ...[
                      Colors.white.withValues(alpha: 0.85),
                      Colors.black.withValues(alpha: 0.55),
                      const Color(0x66FDE047),
                      const Color(0x66EF4444),
                      const Color(0x6610B981),
                      const Color(0x660EA5E9),
                      const Color(0x668B5CF6),
                    ].map((c) {
                      final isSelected = fillColor?.toARGB32() == c.toARGB32();
                      return GestureDetector(
                        onTap: () => onFillColorChanged!(c),
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: c,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isSelected ? AppColors.accent : Colors.black26,
                              width: isSelected ? 2.5 : 1,
                            ),
                          ),
                          child: isSelected
                              ? const Icon(Icons.check_rounded, size: 14, color: Colors.white)
                              : null,
                        ),
                      );
                    }),
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

class _RadiusPresetChip extends StatelessWidget {
  final String label;
  final double radius;
  final bool isSelected;
  final ValueChanged<double> onSelect;
  final Color cardBg;
  final Color textColor;

  const _RadiusPresetChip({
    required this.label,
    required this.radius,
    required this.isSelected,
    required this.onSelect,
    required this.cardBg,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onSelect(radius),
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

class _CircleColorSwatch extends StatelessWidget {
  final Color color;
  final bool isTransparent;
  final bool isSelected;
  final VoidCallback onTap;
  final bool isDarkMode;
  final double size;

  const _CircleColorSwatch({
    required this.color,
    this.isTransparent = false,
    required this.isSelected,
    required this.onTap,
    required this.isDarkMode,
    this.size = 30.0,
  });

  @override
  Widget build(BuildContext context) {
    final hexString = isTransparent
        ? 'Transparent / Erase Fill'
        : '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

    final isLightColor = color == Colors.white || color.computeLuminance() > 0.65;

    return Tooltip(
      message: hexString,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: isTransparent ? Colors.transparent : color,
            shape: BoxShape.circle,
            border: Border.all(
              color: isSelected
                  ? (isDarkMode ? Colors.white : Colors.black87)
                  : (isTransparent
                      ? (isDarkMode ? Colors.white30 : Colors.black26)
                      : (isLightColor
                          ? (isDarkMode ? Colors.white24 : Colors.black26)
                          : (color == Colors.black
                              ? (isDarkMode ? Colors.white24 : Colors.transparent)
                              : Colors.transparent))),
              width: isSelected ? 2.5 : 1.0,
            ),
            boxShadow: isSelected && !isTransparent
                ? [BoxShadow(color: color.withValues(alpha: 0.55), blurRadius: 6)]
                : [],
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (isTransparent) ...[
                const Positioned.fill(
                  child: ClipOval(
                    child: _MiniCheckerboard(),
                  ),
                ),
                if (isSelected)
                  Container(
                    width: size,
                    height: size,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.accent, width: 2.5),
                    ),
                    child: const Icon(Icons.check_rounded, size: 16, color: AppColors.accent),
                  )
                else
                  const Icon(Icons.block_rounded, size: 14, color: Colors.redAccent),
              ] else if (isSelected) ...[
                Icon(
                  Icons.check_rounded,
                  size: 16,
                  color: isLightColor ? Colors.black87 : Colors.white,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniCheckerboard extends StatelessWidget {
  const _MiniCheckerboard();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(48, 48),
      painter: _MiniCheckerPainter(),
    );
  }
}

class _MiniCheckerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const s = 6.0;
    final p1 = Paint()..color = const Color(0xFF8E8E93).withValues(alpha: 0.4);
    final p2 = Paint()..color = const Color(0xFFE5E5EA).withValues(alpha: 0.4);
    int r = 0;
    for (double y = 0; y < size.height; y += s) {
      int c = 0;
      for (double x = 0; x < size.width; x += s) {
        canvas.drawRect(
          Rect.fromLTWH(x, y, math.min(s, size.width - x), math.min(s, size.height - y)),
          (r + c) % 2 == 0 ? p1 : p2,
        );
        c++;
      }
      r++;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}


