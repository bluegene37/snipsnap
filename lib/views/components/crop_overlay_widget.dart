import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../utils/constants.dart';

class CropOverlayWidget extends StatefulWidget {
  final Rect cropRect;
  final ValueChanged<Rect> onCropRectChanged;
  final VoidCallback onApplyCrop;
  final VoidCallback onCancelCrop;
  final bool isDarkMode;

  const CropOverlayWidget({
    super.key,
    required this.cropRect,
    required this.onCropRectChanged,
    required this.onApplyCrop,
    required this.onCancelCrop,
    required this.isDarkMode,
  });

  @override
  State<CropOverlayWidget> createState() => _CropOverlayWidgetState();
}

class _CropOverlayWidgetState extends State<CropOverlayWidget> {
  bool _isDragging = false;

  void _updateRect({
    double? left,
    double? top,
    double? right,
    double? bottom,
    Offset? moveDelta,
  }) {
    double l = left ?? widget.cropRect.left;
    double t = top ?? widget.cropRect.top;
    double r = right ?? widget.cropRect.right;
    double b = bottom ?? widget.cropRect.bottom;

    if (moveDelta != null) {
      l += moveDelta.dx;
      t += moveDelta.dy;
      r += moveDelta.dx;
      b += moveDelta.dy;
    }

    final minL = math.min(l, r);
    final maxR = math.max(l, r);
    final minT = math.min(t, b);
    final maxB = math.max(t, b);

    final finalW = math.max(15.0, maxR - minL);
    final finalH = math.max(15.0, maxB - minT);

    widget.onCropRectChanged(Rect.fromLTWH(minL, minT, finalW, finalH));
  }

  @override
  Widget build(BuildContext context) {
    final rect = widget.cropRect;
    const handleHitSize = 36.0;
    const halfHit = handleHitSize / 2;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // 1. Dark Backdrop + Crop Border Custom Paint
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _CropBorderPainter(cropRect: rect),
            ),
          ),
        ),

        // 2. Central Move Drag Handle (Body)
        if (rect.width > 32 && rect.height > 32)
          Positioned(
            left: rect.left + 16,
            top: rect.top + 16,
            width: rect.width - 32,
            height: rect.height - 32,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (_) => setState(() => _isDragging = true),
              onPanUpdate: (details) => _updateRect(moveDelta: details.delta),
              onPanEnd: (_) => setState(() => _isDragging = false),
              onPanCancel: () => setState(() => _isDragging = false),
            ),
          ),

        // 3. Four Edge Strips
        // Top Edge
        if (rect.width > 40)
          Positioned(
            left: rect.left + 20,
            top: rect.top - 16,
            width: rect.width - 40,
            height: 32,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (_) => setState(() => _isDragging = true),
              onPanUpdate: (details) => _updateRect(top: rect.top + details.delta.dy),
              onPanEnd: (_) => setState(() => _isDragging = false),
              onPanCancel: () => setState(() => _isDragging = false),
            ),
          ),
        // Bottom Edge
        if (rect.width > 40)
          Positioned(
            left: rect.left + 20,
            top: rect.bottom - 16,
            width: rect.width - 40,
            height: 32,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (_) => setState(() => _isDragging = true),
              onPanUpdate: (details) => _updateRect(bottom: rect.bottom + details.delta.dy),
              onPanEnd: (_) => setState(() => _isDragging = false),
              onPanCancel: () => setState(() => _isDragging = false),
            ),
          ),
        // Left Edge
        if (rect.height > 40)
          Positioned(
            left: rect.left - 16,
            top: rect.top + 20,
            width: 32,
            height: rect.height - 40,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (_) => setState(() => _isDragging = true),
              onPanUpdate: (details) => _updateRect(left: rect.left + details.delta.dx),
              onPanEnd: (_) => setState(() => _isDragging = false),
              onPanCancel: () => setState(() => _isDragging = false),
            ),
          ),
        // Right Edge
        if (rect.height > 40)
          Positioned(
            left: rect.right - 16,
            top: rect.top + 20,
            width: 32,
            height: rect.height - 40,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (_) => setState(() => _isDragging = true),
              onPanUpdate: (details) => _updateRect(right: rect.right + details.delta.dx),
              onPanEnd: (_) => setState(() => _isDragging = false),
              onPanCancel: () => setState(() => _isDragging = false),
            ),
          ),

        // 4. Four Corner Handles (Highest Z-Index for gestures)
        // Top-Left
        Positioned(
          left: rect.left - halfHit,
          top: rect.top - halfHit,
          width: handleHitSize,
          height: handleHitSize,
          child: _buildCornerHandle(
            onPanUpdate: (details) => _updateRect(left: rect.left + details.delta.dx, top: rect.top + details.delta.dy),
          ),
        ),
        // Top-Right
        Positioned(
          left: rect.right - halfHit,
          top: rect.top - halfHit,
          width: handleHitSize,
          height: handleHitSize,
          child: _buildCornerHandle(
            onPanUpdate: (details) => _updateRect(right: rect.right + details.delta.dx, top: rect.top + details.delta.dy),
          ),
        ),
        // Bottom-Left
        Positioned(
          left: rect.left - halfHit,
          top: rect.bottom - halfHit,
          width: handleHitSize,
          height: handleHitSize,
          child: _buildCornerHandle(
            onPanUpdate: (details) => _updateRect(left: rect.left + details.delta.dx, bottom: rect.bottom + details.delta.dy),
          ),
        ),
        // Bottom-Right
        Positioned(
          left: rect.right - halfHit,
          top: rect.bottom - halfHit,
          width: handleHitSize,
          height: handleHitSize,
          child: _buildCornerHandle(
            onPanUpdate: (details) => _updateRect(right: rect.right + details.delta.dx, bottom: rect.bottom + details.delta.dy),
          ),
        ),

        // 5. Four Midpoint Edge Square Handles Visual
        _buildMidpointVisual(Offset(rect.center.dx, rect.top)),
        _buildMidpointVisual(Offset(rect.center.dx, rect.bottom)),
        _buildMidpointVisual(Offset(rect.left, rect.center.dy)),
        _buildMidpointVisual(Offset(rect.right, rect.center.dy)),

        // 6. Floating Action Chip Bar ("Apply Crop" / "Cancel")
        if (!_isDragging && rect.width > 10 && rect.height > 10)
          Builder(
            builder: (ctx) {
              final renderObj = context.findRenderObject();
              final canvasH = (renderObj is RenderBox && renderObj.hasSize) ? renderObj.size.height : 800.0;
              final canvasW = (renderObj is RenderBox && renderObj.hasSize) ? renderObj.size.width : 1200.0;

              double barTop = rect.bottom + 20;
              if (barTop > canvasH - 60) {
                barTop = rect.top - 52;
                if (barTop < 12) {
                  barTop = math.max(12, rect.bottom - 56);
                }
              }
              final barLeft = (rect.center.dx - 110).clamp(12.0, math.max(12.0, canvasW - 220)).toDouble();

              return Positioned(
                left: barLeft,
                top: barTop,
                child: Material(
                  color: widget.isDarkMode ? AppColors.darkSurface : AppColors.lightSurface,
                  elevation: 8,
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: AppColors.accent, width: 1.5),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.accent,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          ),
                          icon: const Icon(Icons.check_rounded, size: 16),
                          label: const Text('Apply Crop', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                          onPressed: widget.onApplyCrop,
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          ),
                          icon: const Icon(Icons.close_rounded, size: 16),
                          label: const Text('Cancel', style: TextStyle(fontSize: 12)),
                          onPressed: widget.onCancelCrop,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _buildCornerHandle({required Function(DragUpdateDetails) onPanUpdate}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => setState(() => _isDragging = true),
      onPanUpdate: onPanUpdate,
      onPanEnd: (_) => setState(() => _isDragging = false),
      onPanCancel: () => setState(() => _isDragging = false),
      child: Center(
        child: Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.rectangle,
            borderRadius: BorderRadius.circular(2),
            border: Border.all(color: AppColors.accent, width: 1.6),
            boxShadow: const [
              BoxShadow(color: Colors.black38, blurRadius: 3, offset: Offset(0, 1.5)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMidpointVisual(Offset center) {
    const handleSize = 14.0;
    return Positioned(
      left: center.dx - handleSize / 2,
      top: center.dy - handleSize / 2,
      width: handleSize,
      height: handleSize,
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.rectangle,
            borderRadius: BorderRadius.circular(2),
            border: Border.all(color: AppColors.accent, width: 1.6),
            boxShadow: const [
              BoxShadow(color: Colors.black38, blurRadius: 3, offset: Offset(0, 1.5)),
            ],
          ),
        ),
      ),
    );
  }
}

class _CropBorderPainter extends CustomPainter {
  final Rect cropRect;

  _CropBorderPainter({required this.cropRect});

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Dark semi-transparent background mask around cropRect
    final maskPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.55)
      ..style = PaintingStyle.fill;

    final fullRect = Rect.fromLTWH(-5000, -5000, size.width + 10000, size.height + 10000);
    final path = Path()
      ..addRect(fullRect)
      ..addRect(cropRect);
    path.fillType = PathFillType.evenOdd;
    canvas.drawPath(path, maskPaint);

    // 2. Accent Crop Rect Outline
    final borderPaint = Paint()
      ..color = AppColors.accent
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;
    canvas.drawRect(cropRect, borderPaint);

    // 3. Grid Rule of Thirds Lines
    if (cropRect.width > 60 && cropRect.height > 60) {
      final gridPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.25)
        ..strokeWidth = 1.0
        ..style = PaintingStyle.stroke;

      final w3 = cropRect.width / 3;
      final h3 = cropRect.height / 3;

      // Vertical grid lines
      canvas.drawLine(Offset(cropRect.left + w3, cropRect.top), Offset(cropRect.left + w3, cropRect.bottom), gridPaint);
      canvas.drawLine(Offset(cropRect.left + w3 * 2, cropRect.top), Offset(cropRect.left + w3 * 2, cropRect.bottom), gridPaint);

      // Horizontal grid lines
      canvas.drawLine(Offset(cropRect.left, cropRect.top + h3), Offset(cropRect.right, cropRect.top + h3), gridPaint);
      canvas.drawLine(Offset(cropRect.left, cropRect.top + h3 * 2), Offset(cropRect.right, cropRect.top + h3 * 2), gridPaint);
    }

    // 4. Dimension Badge Pill
    final textSpan = TextSpan(
      text: '${cropRect.width.round()} × ${cropRect.height.round()} px',
      style: const TextStyle(
        color: Colors.white,
        fontSize: 11,
        fontWeight: FontWeight.bold,
      ),
    );
    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();

    final badgeCenter = Offset(cropRect.center.dx, cropRect.top - 18);
    final badgeRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: badgeCenter, width: textPainter.width + 14, height: textPainter.height + 6),
      const Radius.circular(10),
    );
    final badgePaint = Paint()..color = AppColors.accent..style = PaintingStyle.fill;
    canvas.drawRRect(badgeRect, badgePaint);
    textPainter.paint(canvas, badgeCenter - Offset(textPainter.width / 2, textPainter.height / 2));
  }

  @override
  bool shouldRepaint(covariant _CropBorderPainter oldDelegate) {
    return oldDelegate.cropRect != cropRect;
  }
}
