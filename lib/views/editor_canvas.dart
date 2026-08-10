import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../models/annotation.dart';
import '../utils/constants.dart';

class EditorCanvas extends StatefulWidget {
  final String? imagePath;
  final List<Annotation> annotations;
  final CanvasTool activeTool;
  final Color activeColor;
  final double strokeWidth;
  final double fontSize;
  final bool isFilled;
  final int stepCounter;
  final ValueChanged<Annotation> onAnnotationAdded;
  final ValueChanged<int> onStepCounterIncremented;
  final GlobalKey repaintBoundaryKey;
  final bool isDarkMode;
  final double opacity;

  const EditorCanvas({
    super.key,
    required this.imagePath,
    required this.annotations,
    required this.activeTool,
    required this.activeColor,
    required this.strokeWidth,
    required this.fontSize,
    required this.isFilled,
    required this.stepCounter,
    required this.onAnnotationAdded,
    required this.onStepCounterIncremented,
    required this.repaintBoundaryKey,
    this.isDarkMode = true,
    this.opacity = 1.0,
  });

  @override
  State<EditorCanvas> createState() => _EditorCanvasState();
}

class _EditorCanvasState extends State<EditorCanvas> {
  final Uuid _uuid = const Uuid();
  bool _fileExists = false;

  @override
  void initState() {
    super.initState();
    _checkFileExists();
  }

  @override
  void didUpdateWidget(covariant EditorCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imagePath != widget.imagePath) {
      _checkFileExists();
    }
  }

  void _checkFileExists() {
    setState(() {
      _fileExists = widget.imagePath != null && File(widget.imagePath!).existsSync();
    });
  }

  // Current drawing shape state
  Annotation? _currentAnnotation;
  List<Offset> _currentPoints = [];

  void _onPanStart(DragStartDetails details) {
    if (widget.imagePath == null || widget.activeTool == CanvasTool.select) return;

    final pos = details.localPosition;

    if (widget.activeTool == CanvasTool.pen || widget.activeTool == CanvasTool.highlight) {
      _currentPoints = [pos];
      _currentAnnotation = Annotation(
        id: _uuid.v4(),
        tool: widget.activeTool,
        color: widget.activeColor,
        strokeWidth: widget.strokeWidth,
        opacity: widget.opacity,
        points: _currentPoints,
      );
    } else {
      _currentAnnotation = Annotation(
        id: _uuid.v4(),
        tool: widget.activeTool,
        color: widget.activeColor,
        strokeWidth: widget.strokeWidth,
        opacity: widget.opacity,
        startPoint: pos,
        endPoint: pos,
        fill: widget.isFilled,
      );
    }
    setState(() {});
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_currentAnnotation == null) return;

    final pos = details.localPosition;

    if (widget.activeTool == CanvasTool.pen || widget.activeTool == CanvasTool.highlight) {
      setState(() {
        _currentPoints.add(pos);
        _currentAnnotation = _currentAnnotation!.copyWith(points: _currentPoints);
      });
    } else {
      setState(() {
        _currentAnnotation = _currentAnnotation!.copyWith(endPoint: pos);
      });
    }
  }

  void _onPanEnd(DragEndDetails details) {
    if (_currentAnnotation != null) {
      widget.onAnnotationAdded(_currentAnnotation!);
      setState(() {
        _currentAnnotation = null;
        _currentPoints = [];
      });
    }
  }

  void _onTapUp(TapUpDetails details) {
    if (widget.imagePath == null) return;

    final pos = details.localPosition;

    if (widget.activeTool == CanvasTool.stepMarker) {
      final annotation = Annotation(
        id: _uuid.v4(),
        tool: CanvasTool.stepMarker,
        color: widget.activeColor,
        opacity: widget.opacity,
        startPoint: pos,
        stepNumber: widget.stepCounter,
      );
      widget.onAnnotationAdded(annotation);
      widget.onStepCounterIncremented(widget.stepCounter + 1);
    } else if (widget.activeTool == CanvasTool.text) {
      _promptForText(pos);
    }
  }

  void _promptForText(Offset pos) {
    final controller = TextEditingController();
    final dialogBg = widget.isDarkMode ? AppColors.darkSurface : AppColors.lightSurface;
    final textColor = widget.isDarkMode ? Colors.white : Colors.black87;
    final hintColor = widget.isDarkMode ? Colors.white38 : Colors.black38;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: dialogBg,
        title: Text('Add Text Annotation', style: TextStyle(color: textColor)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: textColor),
          decoration: InputDecoration(
            hintText: 'Enter label or comment...',
            hintStyle: TextStyle(color: hintColor),
            enabledBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: AppColors.accent),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: widget.isDarkMode ? Colors.white54 : Colors.black54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent),
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                final annotation = Annotation(
                  id: _uuid.v4(),
                  tool: CanvasTool.text,
                  color: widget.activeColor,
                  opacity: widget.opacity,
                  startPoint: pos,
                  text: controller.text.trim(),
                  fontSize: widget.fontSize,
                );
                widget.onAnnotationAdded(annotation);
              }
              Navigator.pop(ctx);
            },
            child: const Text('Add Text', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.imagePath == null || !_fileExists) {
      final textColor = widget.isDarkMode ? Colors.white : Colors.black87;
      final subTextColor = widget.isDarkMode ? Colors.white54 : Colors.black54;
      final circleBg = widget.isDarkMode
          ? AppColors.darkSurface.withValues(alpha: 0.5)
          : AppColors.lightSurface;
      final borderColor = widget.isDarkMode ? Colors.white10 : Colors.black12;

      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: circleBg,
                shape: BoxShape.circle,
                border: Border.all(color: borderColor),
              ),
              child: const Icon(Icons.add_a_photo_rounded, size: 56, color: AppColors.accent),
            ),
            const SizedBox(height: 16),
            Text(
              'No Screenshot Selected',
              style: TextStyle(color: textColor, fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'Click "Snip" in the top bar to capture screen area, or open an existing image.',
              style: TextStyle(color: subTextColor, fontSize: 13),
            ),
          ],
        ),
      );
    }

    return Center(
      child: InteractiveViewer(
        maxScale: 4.0,
        minScale: 0.5,
        panEnabled: widget.activeTool == CanvasTool.select,
        child: RepaintBoundary(
          key: widget.repaintBoundaryKey,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Background Screenshot Image
              Image.file(
                File(widget.imagePath!),
                fit: BoxFit.contain,
              ),

              // Interactive Gesture Overlay + CustomPainter
              Positioned.fill(
                child: GestureDetector(
                  onPanStart: _onPanStart,
                  onPanUpdate: _onPanUpdate,
                  onPanEnd: _onPanEnd,
                  onTapUp: _onTapUp,
                  child: CustomPaint(
                    painter: _AnnotationPainter(
                      annotations: widget.annotations,
                      currentAnnotation: _currentAnnotation,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AnnotationPainter extends CustomPainter {
  final List<Annotation> annotations;
  final Annotation? currentAnnotation;

  _AnnotationPainter({required this.annotations, this.currentAnnotation});

  @override
  void paint(Canvas canvas, Size size) {
    final allAnnotations = [...annotations, ?currentAnnotation];
    for (final ann in allAnnotations) {
      final effectiveAlpha = (ann.color.a * ann.opacity).clamp(0.0, 1.0);
      final paint = Paint()
        ..color = ann.color.withValues(alpha: effectiveAlpha)
        ..strokeWidth = ann.strokeWidth
        ..style = ann.fill ? PaintingStyle.fill : PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      switch (ann.tool) {
        case CanvasTool.pen:
          if (ann.points.length > 1) {
            for (int i = 0; i < ann.points.length - 1; i++) {
              canvas.drawLine(ann.points[i], ann.points[i + 1], paint);
            }
          }
          break;

        case CanvasTool.highlight:
          final hlAlpha = (0.4 * ann.opacity).clamp(0.0, 1.0);
          final hlPaint = Paint()
            ..color = ann.color.withValues(alpha: hlAlpha)
            ..strokeWidth = ann.strokeWidth * 3
            ..strokeCap = StrokeCap.square
            ..style = PaintingStyle.stroke;
          if (ann.points.length > 1) {
            for (int i = 0; i < ann.points.length - 1; i++) {
              canvas.drawLine(ann.points[i], ann.points[i + 1], hlPaint);
            }
          }
          break;

        case CanvasTool.arrow:
          if (ann.startPoint != null && ann.endPoint != null) {
            _drawArrow(canvas, ann.startPoint!, ann.endPoint!, paint);
          }
          break;

        case CanvasTool.line:
          if (ann.startPoint != null && ann.endPoint != null) {
            canvas.drawLine(ann.startPoint!, ann.endPoint!, paint);
          }
          break;

        case CanvasTool.rectangle:
          if (ann.startPoint != null && ann.endPoint != null) {
            final rect = Rect.fromPoints(ann.startPoint!, ann.endPoint!);
            final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(4));
            canvas.drawRRect(rrect, paint);
          }
          break;

        case CanvasTool.oval:
          if (ann.startPoint != null && ann.endPoint != null) {
            final rect = Rect.fromPoints(ann.startPoint!, ann.endPoint!);
            canvas.drawOval(rect, paint);
          }
          break;

        case CanvasTool.blur:
          if (ann.startPoint != null && ann.endPoint != null) {
            final rect = Rect.fromPoints(ann.startPoint!, ann.endPoint!);
            final blurPaint = Paint()
              ..color = Colors.black.withValues(alpha: 0.85)
              ..style = PaintingStyle.fill;
            canvas.drawRect(rect, blurPaint);

            final patternPaint = Paint()
              ..color = Colors.white24
              ..strokeWidth = 2;
            for (double x = rect.left; x < rect.right; x += 10) {
              canvas.drawLine(Offset(x, rect.top), Offset(x + 10, rect.bottom), patternPaint);
            }
          }
          break;

        case CanvasTool.stepMarker:
          if (ann.startPoint != null && ann.stepNumber != null) {
            _drawStepMarker(canvas, ann.startPoint!, ann.stepNumber!, ann.color);
          }
          break;

        case CanvasTool.text:
          if (ann.startPoint != null && ann.text != null) {
            _drawText(canvas, ann.startPoint!, ann.text!, ann.color, ann.fontSize);
          }
          break;

        default:
          break;
      }
    }
  }

  void _drawArrow(Canvas canvas, Offset start, Offset end, Paint paint) {
    canvas.drawLine(start, end, paint);

    final angle = math.atan2(end.dy - start.dy, end.dx - start.dx);
    const arrowSize = 16.0;

    final path = Path();
    path.moveTo(end.dx, end.dy);
    path.lineTo(
      end.dx - arrowSize * math.cos(angle - math.pi / 6),
      end.dy - arrowSize * math.sin(angle - math.pi / 6),
    );
    path.lineTo(
      end.dx - arrowSize * math.cos(angle + math.pi / 6),
      end.dy - arrowSize * math.sin(angle + math.pi / 6),
    );
    path.close();

    final headPaint = Paint()
      ..color = paint.color
      ..style = PaintingStyle.fill;

    canvas.drawPath(path, headPaint);
  }

  void _drawStepMarker(Canvas canvas, Offset center, int step, Color color) {
    const radius = 16.0;

    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.3)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    canvas.drawCircle(center + const Offset(0, 2), radius, shadowPaint);

    final bodyPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius, bodyPaint);

    final borderPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(center, radius, borderPaint);

    final textPainter = TextPainter(
      text: TextSpan(
        text: '$step',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      center - Offset(textPainter.width / 2, textPainter.height / 2),
    );
  }

  void _drawText(Canvas canvas, Offset position, String text, Color color, double fontSize) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
          shadows: const [
            Shadow(color: Colors.black54, offset: Offset(1, 1), blurRadius: 3),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();

    final bgRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        position.dx - 6,
        position.dy - 4,
        textPainter.width + 12,
        textPainter.height + 8,
      ),
      const Radius.circular(6),
    );

    final bgPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.7)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(bgRect, bgPaint);

    final borderPaint = Paint()
      ..color = color.withValues(alpha: 0.6)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    canvas.drawRRect(bgRect, borderPaint);

    textPainter.paint(canvas, position);
  }

  @override
  bool shouldRepaint(covariant _AnnotationPainter oldDelegate) {
    return oldDelegate.annotations != annotations || oldDelegate.currentAnnotation != currentAnnotation;
  }
}
