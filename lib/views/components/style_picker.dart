import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../models/annotation.dart';
import '../../utils/constants.dart';
import '../../utils/snip_theme.dart';
import '../dialogs/color_picker_dialog.dart';

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
  final CanvasTool activeTool;
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

  /// User-saved swatches, shown after the stock palette in every colour
  /// section. Saving happens from the custom colour dialog; right-click (or
  /// long-press) a saved swatch to remove it.
  final List<Color> savedColors;
  final ValueChanged<Color>? onSaveColor;
  final ValueChanged<Color>? onRemoveSavedColor;

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
    required this.activeTool,
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
    this.savedColors = const [],
    this.onSaveColor,
    this.onRemoveSavedColor,
  });

  void _showColorPickerDialog(BuildContext context) {
    showSnipColorPicker(
      context: context,
      title: 'Pick Color',
      initialColor: selectedColor,
      onColorChanged: onColorChanged,
      onSaveColor: onSaveColor,
    );
  }

  /// The saved-swatch strip appended to a colour section's Wrap. [onPick]
  /// selects the swatch; removal is right-click or long-press so a plain tap
  /// never destroys data.
  List<Widget> _savedColorSwatches({
    required SnipTheme t,
    required ValueChanged<Color> onPick,
    Color? selectedAgainst,
    Color Function(Color)? applied,
  }) {
    final current = selectedAgainst ?? selectedColor;
    if (savedColors.isEmpty) return const [];
    return [
      for (final color in savedColors)
        GestureDetector(
          onSecondaryTap:
              onRemoveSavedColor == null ? null : () => onRemoveSavedColor!(color),
          onLongPress:
              onRemoveSavedColor == null ? null : () => onRemoveSavedColor!(color),
          child: _CircleColorSwatch(
            // Drawn as saved; compared and applied through [applied], which is
            // how a section that owns its own transparency keeps the swatch
            // itself readable.
            color: color,
            isSelected: current.toARGB32() ==
                (applied?.call(color) ?? color).toARGB32(),
            onTap: () => onPick(color),
            size: 30,
            backdrop: t.surface,
            tooltip:
                'Saved #${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}'
                ' — right-click or long-press to remove',
          ),
        ),
    ];
  }

  /// The colour the fill actually renders as. A null [fillColor] means "match
  /// the outline", which is what `AnnotationRenderer` falls back to.
  Color get _effectiveFillColor => fillColor ?? selectedColor;

  /// The fill's own transparency, carried in its colour's alpha channel rather
  /// than as a separate field — it is already persisted and already multiplied
  /// by the annotation's overall opacity at paint time.
  double get _fillOpacity => _effectiveFillColor.a;

  void _showFillColorPickerDialog(BuildContext context) {
    showSnipColorPicker(
      context: context,
      title: 'Pick Fill Colour',
      initialColor: _effectiveFillColor,
      onColorChanged: (c) => onFillColorChanged?.call(c),
      onSaveColor: onSaveColor,
    );
  }

  void _showBgColorPickerDialog(BuildContext context) {
    showSnipColorPicker(
      context: context,
      title: 'Pick Text Background Color',
      initialColor: textBackgroundColor ?? Colors.black.withValues(alpha: 0.75),
      onColorChanged: (c) {
        onTextBackgroundColorChanged?.call(c);
        onFillChanged(true);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = SnipTheme.of(context);
    final effectiveTool = selectedAnnotation?.tool ?? activeTool;
    final effectiveShapeKind = selectedAnnotation?.shapeKind ?? shapeKind;

    // Thickness is drag-set for some marks, and a slider showing the same
    // property would only be a second, coarser way to do it — capped lower than
    // the drag allows, at that. See [dragSizedStrokeTools].
    final showStroke = [
      CanvasTool.pen,
      CanvasTool.arrow,
      CanvasTool.line,
      CanvasTool.shape,
      CanvasTool.highlight,
      CanvasTool.ruler,
    ].contains(effectiveTool) &&
        !dragSizedStrokeTools.contains(effectiveTool);

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

    final showColor = [
      CanvasTool.pen,
      CanvasTool.arrow,
      CanvasTool.line,
      CanvasTool.shape,
      CanvasTool.highlight,
      CanvasTool.text,
      CanvasTool.stepMarker,
      CanvasTool.ruler,
    ].contains(effectiveTool) || (selectedAnnotation != null && effectiveTool != CanvasTool.blur && effectiveTool != CanvasTool.crop);

    final showOpacity = [
      CanvasTool.pen,
      CanvasTool.arrow,
      CanvasTool.line,
      CanvasTool.shape,
      CanvasTool.highlight,
      CanvasTool.text,
      CanvasTool.stepMarker,
      CanvasTool.blur,
      CanvasTool.ruler,
    ].contains(effectiveTool) || (selectedAnnotation != null && effectiveTool != CanvasTool.crop);


    final bgColor = t.surface;
    final textColor = t.ink;
    final subTextColor = t.inkMuted;
    final borderColor = t.border;
    final cardBg = t.surfaceRaised;

    final sliderThemeData = SliderThemeData(
      activeTrackColor: t.ink,
      inactiveTrackColor: t.border,
      thumbColor: t.ink,
      trackHeight: 3,
    );

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
                    Icon(
                      selectedAnnotation != null ? Icons.layers_rounded : Icons.tune_rounded,
                      color: t.ink,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      selectedAnnotation != null ? 'Item Properties' : 'Tool Properties',
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

            // Selected Item Quick Actions Row
            if (selectedAnnotation != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: borderColor),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    if (onBringToFront != null)
                      Tooltip(
                        message: 'Bring to Front',
                        child: IconButton(
                          icon: const Icon(Icons.flip_to_front_rounded, size: 16),
                          color: textColor,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 32, minHeight: 30),
                          onPressed: onBringToFront,
                        ),
                      ),
                    if (onSendToBack != null)
                      Tooltip(
                        message: 'Send to Back',
                        child: IconButton(
                          icon: const Icon(Icons.flip_to_back_rounded, size: 16),
                          color: textColor,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 32, minHeight: 30),
                          onPressed: onSendToBack,
                        ),
                      ),
                    if (onDeleteSelected != null)
                      Tooltip(
                        message: 'Delete Selected (Del)',
                        child: IconButton(
                          icon: Icon(Icons.delete_outline_rounded, size: 16, color: t.danger),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 32, minHeight: 30),
                          onPressed: onDeleteSelected,
                        ),
                      ),
                    if (onDeselect != null)
                      Tooltip(
                        message: 'Deselect (Esc)',
                        child: IconButton(
                          icon: Icon(Icons.close_rounded, size: 16, color: subTextColor),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 32, minHeight: 30),
                          onPressed: onDeselect,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Context Card: Selection Tool (when no item selected)
            if (activeTool == CanvasTool.select && selectedAnnotation == null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: t.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.crop_free_rounded, color: t.ink, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          'Selection & Cut',
                          style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 12),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '• Drag over the image to create a selection.\n• Drag inside to cut & move.\n• Press Delete to erase to transparent.\n• Click any annotation on canvas to edit its properties.',
                      style: TextStyle(color: subTextColor, fontSize: 11, height: 1.4),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Context Card: Crop Tool
            if (activeTool == CanvasTool.crop) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: t.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.crop_rounded, color: t.ink, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          'Crop & Canvas Bounds',
                          style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 12),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '• Drag handles inward to crop image.\n• Drag handles outward to expand canvas with transparent space.\n• Press Enter to commit changes.',
                      style: TextStyle(color: subTextColor, fontSize: 11, height: 1.4),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Context Card: OCR Tool
            if (activeTool == CanvasTool.ocr) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: t.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.text_fields_rounded, color: t.ink, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          'OCR Text Extraction',
                          style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 12),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '• Drag a rectangle over any text in the screenshot to extract it.\n• Click canvas to extract text from the entire screenshot.\n• Extracted text is copied directly to clipboard.',
                      style: TextStyle(color: subTextColor, fontSize: 11, height: 1.4),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Context Card: Eyedropper Color Picker Tool
            if (activeTool == CanvasTool.colorPicker) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: t.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.colorize_rounded, color: t.ink, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          'Color Eyedropper',
                          style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 12),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '• Hover and click anywhere on the screenshot to sample the pixel color into your active tool.',
                      style: TextStyle(color: subTextColor, fontSize: 11, height: 1.4),
                    ),
                    const SizedBox(height: 10),
                    // The sampled colour is almost never one of the preset
                    // swatches, so without an explicit readout nothing in this
                    // panel shows what the eyedropper just picked up.
                    _CurrentColorReadout(
                      color: selectedColor,
                      label: 'SAMPLED',
                      onTap: () => _showColorPickerDialog(context),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Dedicated Fill Tool Section
            if (activeTool == CanvasTool.fill) ...[
              Text(
                'FILL COLOR',
                style: TextStyle(
                  color: subTextColor,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 10),
              _CurrentColorReadout(
                color: selectedColor,
                onTap: () => _showColorPickerDialog(context),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _CircleColorSwatch(
                    color: Colors.transparent,
                    isTransparent: true,
                    isSelected: opacity <= 0.05 || selectedColor.a == 0,
                    onTap: () {
                      onColorChanged(Colors.transparent);
                      onOpacityChanged(0.0);
                    },
                    size: 30,
                  ),
                  ...AppColors.palette.map((color) {
                    final isSelected = selectedColor.toARGB32() == color.toARGB32() && opacity > 0.05;
                    return _CircleColorSwatch(
                      color: color,
                      isSelected: isSelected,
                      onTap: () {
                        onColorChanged(color);
                        if (opacity <= 0.05) onOpacityChanged(1.0);
                      },
                      size: 30,
                    );
                  }),
                  ..._savedColorSwatches(
                    t: t,
                    onPick: (color) {
                      onColorChanged(color);
                      // A saved colour is always an opaque pick — leaving the
                      // eraser's 0% opacity behind would make it a silent no-op.
                      if (opacity <= 0.05) onOpacityChanged(1.0);
                    },
                  ),
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
                  if (onActivateEyedropper != null)
                    Tooltip(
                      message: 'Sample color from screen',
                      child: GestureDetector(
                        onTap: onActivateEyedropper,
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: cardBg,
                            shape: BoxShape.circle,
                            border: Border.all(color: borderColor),
                          ),
                          child: Icon(Icons.colorize_rounded, size: 16, color: textColor),
                        ),
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
                data: sliderThemeData,
                child: Slider(
                  value: fillTolerance.clamp(0.0, 100.0),
                  min: 0.0,
                  max: 100.0,
                  onChanged: onFillToleranceChanged,
                ),
              ),
              const SizedBox(height: 12),

              // Opacity Slider for Fill
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
                data: sliderThemeData,
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
                          activeColor: t.activeFill,
                          checkColor: t.onActive,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Global Fill (All matching pixels)',
                        style: TextStyle(color: textColor, fontSize: 12, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Shape Chooser Grid (when Shape tool is active or shape is selected)
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
                          decoration: t.controlDecoration(active: isSelected, radius: 8),
                          child: Icon(
                            kind.icon,
                            size: 20,
                            color: t.controlForeground(active: isSelected),
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 20),
            ],

            // Step Marker Info Card (when Step Marker tool is active or selected)
            if (effectiveTool == CanvasTool.stepMarker) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: t.border),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: t.ink,
                            shape: BoxShape.circle,
                          ),
                          child: Center(
                            child: Text(
                              '$stepCounter',
                              style: TextStyle(color: t.onActive, fontWeight: FontWeight.bold, fontSize: 13),
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
                                  foregroundColor: t.ink,
                                  side: BorderSide(color: t.border),
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
                                  foregroundColor: t.ink,
                                  side: BorderSide(color: t.border),
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

            // Primary Color Swatches Grid (for tools that use color)
            if (showColor) ...[
              Text(
                effectiveTool == CanvasTool.text
                    ? 'TEXT COLOR'
                    : (effectiveTool == CanvasTool.highlight
                        ? 'HIGHLIGHTER TINT'
                        : (effectiveTool == CanvasTool.stepMarker ? 'BADGE COLOR' : 'COLOR')),
                style: TextStyle(
                  color: subTextColor,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 10),
              // A colour picked with the eyedropper or the custom picker is
              // usually off-palette, so no swatch below reads as selected.
              // This is the one place the active colour is always visible.
              _CurrentColorReadout(
                color: selectedColor,
                onTap: () => _showColorPickerDialog(context),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  ...(effectiveTool == CanvasTool.highlight
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
                    return _CircleColorSwatch(
                      color: color,
                      isSelected: isSelected,
                      onTap: () => onColorChanged(color),
                      size: 30,
                    );
                  }),
                  ..._savedColorSwatches(t: t, onPick: onColorChanged),
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
                  if (onActivateEyedropper != null)
                    Tooltip(
                      message: 'Sample color from screen',
                      child: GestureDetector(
                        onTap: onActivateEyedropper,
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: cardBg,
                            shape: BoxShape.circle,
                            border: Border.all(color: borderColor),
                          ),
                          child: Icon(Icons.colorize_rounded, size: 16, color: textColor),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 20),
            ],

            // Line Thickness Controls (Presets + Slider)
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

              // Presets with Row + Expanded so they adapt smoothly without overflow
              Row(
                children: [
                  Expanded(
                    child: _StrokePresetChip(
                      label: '2px',
                      width: AppDefaults.strokeWidthThin,
                      isSelected: (strokeWidth - AppDefaults.strokeWidthThin).abs() < 0.5,
                      onSelect: onStrokeWidthChanged,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _StrokePresetChip(
                      label: '4px',
                      width: AppDefaults.strokeWidthMedium,
                      isSelected: (strokeWidth - AppDefaults.strokeWidthMedium).abs() < 0.5,
                      onSelect: onStrokeWidthChanged,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _StrokePresetChip(
                      label: '8px',
                      width: AppDefaults.strokeWidthThick,
                      isSelected: (strokeWidth - AppDefaults.strokeWidthThick).abs() < 0.5,
                      onSelect: onStrokeWidthChanged,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _StrokePresetChip(
                      label: '14px',
                      width: AppDefaults.strokeWidthHeavy,
                      isSelected: (strokeWidth - AppDefaults.strokeWidthHeavy).abs() < 0.5,
                      onSelect: onStrokeWidthChanged,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),

              SliderTheme(
                data: sliderThemeData,
                child: Slider(
                  value: strokeWidth.clamp(1.0, 30.0),
                  min: 1.0,
                  max: 30.0,
                  onChanged: onStrokeWidthChanged,
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Opacity Slider (for tools that support opacity)
            if (showOpacity) ...[
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
                data: sliderThemeData,
                child: Slider(
                  value: opacity.clamp(0.1, 1.0),
                  min: 0.1,
                  max: 1.0,
                  onChanged: onOpacityChanged,
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Corner Radius (rectangles, speech bubbles, text boxes, blur boxes)
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
                children: [
                  Expanded(
                    child: _RadiusPresetChip(
                      label: '0px',
                      radius: 0.0,
                      isSelected: borderRadius == 0.0,
                      onSelect: (r) => onBorderRadiusChanged?.call(r),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _RadiusPresetChip(
                      label: '8px',
                      radius: 8.0,
                      isSelected: borderRadius == 8.0,
                      onSelect: (r) => onBorderRadiusChanged?.call(r),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _RadiusPresetChip(
                      label: '16px',
                      radius: 16.0,
                      isSelected: borderRadius == 16.0,
                      onSelect: (r) => onBorderRadiusChanged?.call(r),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _RadiusPresetChip(
                      label: '24px',
                      radius: 24.0,
                      isSelected: borderRadius == 24.0,
                      onSelect: (r) => onBorderRadiusChanged?.call(r),
                    ),
                  ),
                ],
              ),
              SliderTheme(
                data: sliderThemeData,
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
                      label: Center(
                        child: Text('Solid',
                            style: TextStyle(
                                fontSize: 11,
                                color: t.controlForeground(active: lineStyle == LineStyle.solid))),
                      ),
                      selected: lineStyle == LineStyle.solid,
                      backgroundColor: Colors.transparent,
                      selectedColor: t.activeFill,
                      checkmarkColor: t.onActive,
                      side: BorderSide(color: t.border),
                      onSelected: (selected) {
                        if (selected) onLineStyleChanged?.call(LineStyle.solid);
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilterChip(
                      label: Center(
                        child: Text('Dashed',
                            style: TextStyle(
                                fontSize: 11,
                                color: t.controlForeground(active: lineStyle == LineStyle.dashed))),
                      ),
                      selected: lineStyle == LineStyle.dashed,
                      backgroundColor: Colors.transparent,
                      selectedColor: t.activeFill,
                      checkmarkColor: t.onActive,
                      side: BorderSide(color: t.border),
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
                    activeTrackColor: t.activeFill,
                    onChanged: (val) => onDoubleArrowChanged?.call(val),
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],

            // Blur Mode & Strength
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
                      label: Center(
                        child: Text('Blur',
                            style: TextStyle(
                                fontSize: 10.5,
                                color: t.controlForeground(active: blurType == BlurType.gaussian))),
                      ),
                      selected: blurType == BlurType.gaussian,
                      backgroundColor: Colors.transparent,
                      selectedColor: t.activeFill,
                      checkmarkColor: t.onActive,
                      side: BorderSide(color: t.border),
                      onSelected: (selected) {
                        if (selected) onBlurTypeChanged?.call(BlurType.gaussian);
                      },
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: FilterChip(
                      label: Center(
                        child: Text('Pixelate',
                            style: TextStyle(
                                fontSize: 10.5,
                                color: t.controlForeground(active: blurType == BlurType.pixelate))),
                      ),
                      selected: blurType == BlurType.pixelate,
                      backgroundColor: Colors.transparent,
                      selectedColor: t.activeFill,
                      checkmarkColor: t.onActive,
                      side: BorderSide(color: t.border),
                      onSelected: (selected) {
                        if (selected) onBlurTypeChanged?.call(BlurType.pixelate);
                      },
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: FilterChip(
                      label: Center(
                        child: Text('Blackout',
                            style: TextStyle(
                                fontSize: 10.5,
                                color: t.controlForeground(active: blurType == BlurType.solid))),
                      ),
                      selected: blurType == BlurType.solid,
                      backgroundColor: Colors.transparent,
                      selectedColor: t.activeFill,
                      checkmarkColor: t.onActive,
                      side: BorderSide(color: t.border),
                      onSelected: (selected) {
                        if (selected) onBlurTypeChanged?.call(BlurType.solid);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              if (blurType != BlurType.solid) ...[
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
                  data: sliderThemeData,
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

            // Font Size Slider (for text and step markers)
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
                data: sliderThemeData,
                child: Slider(
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
                    activeTrackColor: t.activeFill,
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

              // Text Background Color Palette Swatches
              if (effectiveTool == CanvasTool.text) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
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
                              color: (!isFilled || textBackgroundColor == null) ? t.ink : borderColor,
                              width: (!isFilled || textBackgroundColor == null) ? 2.5 : 1,
                            ),
                          ),
                          child: Icon(Icons.block_rounded, size: 14, color: t.inkMuted),
                        ),
                      ),
                    ),
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
                      final ring = isSelected ? t.ringOn(bgC, backdrop: t.surface) : null;
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
                              color: ring ?? t.border,
                              width: isSelected ? 2.5 : 1,
                            ),
                          ),
                          child: ring == null
                              ? null
                              : Icon(Icons.check_rounded, size: 14, color: ring),
                        ),
                      );
                    }),
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

              // Shape Fill Colour — the same palette, saved swatches and
              // custom picker the outline colour gets, plus a transparency of
              // its own. The fill used to offer seven fixed pre-tinted colours
              // and nothing else, so it could not be set to a colour the rest
              // of the panel could.
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
                const SizedBox(height: 10),
                _CurrentColorReadout(
                  color: _effectiveFillColor,
                  label: 'FILL',
                  paintSolid: true,
                  onTap: () => _showFillColorPickerDialog(context),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    Tooltip(
                      message: 'Match the outline colour',
                      child: GestureDetector(
                        onTap: () => onFillColorChanged!(null),
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: selectedColor,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: fillColor == null ? t.ink : borderColor,
                              width: fillColor == null ? 2.5 : 1,
                            ),
                          ),
                          child: Icon(
                            Icons.auto_awesome_rounded,
                            size: 13,
                            color: t.controlForeground(active: true),
                          ),
                        ),
                      ),
                    ),
                    // Each swatch is painted at full strength and *applied* at
                    // the current fill transparency. Painting them tinted made
                    // the whole row fade out as the opacity slider came down,
                    // until picking a colour meant guessing at a set of nearly
                    // identical ghosts — the transparency belongs to the mark
                    // being edited, not to the control that chooses its colour.
                    ...AppColors.palette.map((color) {
                      final applied = color.withValues(alpha: _fillOpacity);
                      return _CircleColorSwatch(
                        color: color,
                        isSelected: fillColor != null &&
                            fillColor!.toARGB32() == applied.toARGB32(),
                        onTap: () => onFillColorChanged!(applied),
                        size: 30,
                        backdrop: t.surface,
                      );
                    }),
                    ..._savedColorSwatches(
                      t: t,
                      selectedAgainst: fillColor ?? const Color(0x00000000),
                      applied: (c) => c.withValues(alpha: _fillOpacity),
                      onPick: (c) =>
                          onFillColorChanged!(c.withValues(alpha: _fillOpacity)),
                    ),
                    Tooltip(
                      message: 'Custom Fill Colour',
                      child: GestureDetector(
                        onTap: () => _showFillColorPickerDialog(context),
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
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'FILL OPACITY',
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
                        '${(_fillOpacity * 100).round()}%',
                        style: TextStyle(
                            color: textColor, fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                SliderTheme(
                  data: sliderThemeData,
                  child: Slider(
                    value: _fillOpacity.clamp(0.0, 1.0),
                    min: 0.0,
                    max: 1.0,
                    // Separate from the annotation's own opacity slider, which
                    // fades the outline too. This one is the fill alone, so a
                    // shape can have a solid border over a translucent centre.
                    onChanged: (v) =>
                        onFillColorChanged!(_effectiveFillColor.withValues(alpha: v)),
                  ),
                ),
              ],
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
                    activeTrackColor: t.activeFill,
                    onChanged: (val) => onShadowChanged!(val),
                  ),
                ],
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
                      backgroundColor: t.surfaceRaised,
                      foregroundColor: t.emphasis,
                      side: BorderSide(color: t.emphasis, width: 1.2),
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

  const _StrokePresetChip({
    required this.label,
    required this.width,
    required this.isSelected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final t = SnipTheme.of(context);
    return GestureDetector(
      onTap: () => onSelect(width),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 5),
        alignment: Alignment.center,
        decoration: t.controlDecoration(active: isSelected, radius: 6),
        child: Text(
          label,
          style: TextStyle(
            color: t.controlForeground(active: isSelected),
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

  const _RadiusPresetChip({
    required this.label,
    required this.radius,
    required this.isSelected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final t = SnipTheme.of(context);
    return GestureDetector(
      onTap: () => onSelect(radius),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 5),
        alignment: Alignment.center,
        decoration: t.controlDecoration(active: isSelected, radius: 6),
        child: Text(
          label,
          style: TextStyle(
            color: t.controlForeground(active: isSelected),
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

/// One annotation-colour swatch. The fill is real, saturated colour — data,
/// not chrome — pulled straight from [AppColors.palette] or a tool's own
/// preset list, and stays untouched by the skeleton conversion. Only the
/// ring around it is chrome: [SnipTheme.ringOn] for the selected ring (picks
/// whichever of [SnipTheme.ink]/[SnipTheme.onActive] actually contrasts
/// against this swatch's own colour, rather than a fixed [SnipTheme.ink]
/// that vanishes against a pure-black or pure-white swatch),
/// [SnipTheme.border] for the quiet "this swatch needs a touch of
/// definition against the panel" ring some unselected swatches still carry.
/// See `SnipTheme`'s class doc and the task-4 report for why the fill and
/// the ring are governed by two different rules.
class _CircleColorSwatch extends StatelessWidget {
  final Color color;
  final bool isTransparent;
  final bool isSelected;
  final VoidCallback onTap;
  final double size;
  final String? tooltip;

  /// What the swatch is drawn over.
  ///
  /// Load-bearing for any swatch carrying alpha: a translucent fill composites
  /// against the panel, and scoring the ring against the raw colour instead
  /// picks a glyph that disappears once it is actually painted.
  final Color? backdrop;

  const _CircleColorSwatch({
    required this.color,
    this.isTransparent = false,
    required this.isSelected,
    required this.onTap,
    this.size = 30.0,
    this.tooltip,
    this.backdrop,
  });

  @override
  Widget build(BuildContext context) {
    final t = SnipTheme.of(context);
    final hexString = tooltip ??
        (isTransparent
            ? 'Transparent / Erase Fill'
            : '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}');

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
                  // The swatch's own fill is real, arbitrary colour data —
                  // t.ink alone would drop to ~1.1:1 (invisible) against a
                  // pure-black swatch in light mode or pure-white in dark
                  // mode, both live AppColors.palette entries. Not a
                  // meaningful ring colour for the transparent tile (no
                  // single fill to contrast against), which keeps t.ink.
                  ? (isTransparent ? t.ink : t.ringOn(color, backdrop: backdrop))
                  : (isTransparent
                      ? t.border
                      : (isLightColor
                          ? t.border
                          : (color == Colors.black && t.isDark ? t.border : Colors.transparent))),
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
                      border: Border.all(color: t.ink, width: 2.5),
                    ),
                    child: Icon(Icons.check_rounded, size: 16, color: t.ink),
                  )
                else
                  Icon(Icons.block_rounded, size: 14, color: t.inkMuted),
              ] else if (isSelected) ...[
                Icon(
                  Icons.check_rounded,
                  size: 16,
                  // The same colour as the ring around it, from the same
                  // helper. A hand-rolled light/dark rule sat here before and
                  // disagreed with the ring on some swatches — and it read the
                  // raw colour, so a translucent fill was scored against a
                  // colour that is never actually on screen.
                  color: t.ringOn(color, backdrop: backdrop),
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



/// The active colour, shown as a swatch plus its hex value.
///
/// The swatch grid can only ever highlight a preset: a colour arriving from
/// the eyedropper or the custom picker matches nothing there, so before this
/// existed the panel gave no indication of what the current colour actually
/// was. Tapping it reopens the custom picker on that colour.
class _CurrentColorReadout extends StatelessWidget {
  final Color color;
  final String label;
  final VoidCallback onTap;

  /// Paint the swatch at full strength even when [color] carries alpha. The
  /// hex and percentage still report the real value; only the tile stops
  /// fading — for the fill, a tile that thins out with the slider reads as the
  /// colour itself changing, which is not what the slider does.
  final bool paintSolid;

  const _CurrentColorReadout({
    required this.color,
    required this.onTap,
    this.label = 'CURRENT',
    this.paintSolid = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = SnipTheme.of(context);
    final hex =
        '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
    final alphaPct = (color.a * 100).round();

    return Tooltip(
      message: 'Current color $hex — tap to open the custom picker',
      child: InkWell(
        borderRadius: BorderRadius.circular(t.radius),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(t.radius),
            border: Border.all(color: t.border, width: t.hairline),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: CustomPaint(
                    painter: const CheckerboardPainter(),
                    child: Container(
                      decoration: BoxDecoration(
                        color: paintSolid ? color.withValues(alpha: 1.0) : color,
                        border: Border.all(color: t.border, width: t.hairline),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: t.inkMuted,
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.6,
                      ),
                    ),
                    Text(
                      alphaPct >= 100 ? hex : '$hex · $alphaPct%',
                      style: TextStyle(
                        color: t.ink,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.color_lens_rounded, size: 14, color: t.inkMuted),
            ],
          ),
        ),
      ),
    );
  }
}
