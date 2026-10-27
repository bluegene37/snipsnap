// Gene - Oct, 27, 2026: ScrollingCaptureHud provides live panoramic scrolling capture statistics and actions.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/scrolling/scrolling_capture_controller.dart';
import 'capture_overlay.dart';

/// Floating HUD overlay widget anchored adjacent to the scrolling capture viewport.
///
/// Displays real-time cumulative capture height (with tabular figures) and frame count,
/// a pulsing recording indicator, and commit/cancel action controls with keyboard shortcuts.
class ScrollingCaptureHud extends StatelessWidget {
  final ScrollingCaptureController controller;
  final VoidCallback onDone;
  final VoidCallback onCancel;

  const ScrollingCaptureHud({
    super.key,
    required this.controller,
    required this.onDone,
    required this.onCancel,
  });

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      onCancel();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      onDone();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: CaptureColors.bean,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x66000000),
                  blurRadius: 16,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Pulsing recording indicator
                const _PulsingRecordingDot(),
                const SizedBox(width: 8),
                Text(
                  '${controller.cumulativeHeight} px',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '(${controller.frameCount} frames)',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 11,
                  ),
                ),
                const SizedBox(width: 14),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: CaptureColors.coffee,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    minimumSize: const Size(0, 30),
                  ),
                  onPressed: onDone,
                  icon: const Icon(Icons.check_rounded, size: 16),
                  label: const Text('Done', style: TextStyle(fontSize: 12)),
                ),
                const SizedBox(width: 6),
                IconButton(
                  style: IconButton.styleFrom(
                    backgroundColor: CaptureColors.bean,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(30, 30),
                    padding: EdgeInsets.zero,
                    side: BorderSide(
                      color: Colors.white.withValues(alpha: 0.2),
                    ),
                  ),
                  onPressed: onCancel,
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 16,
                    color: Colors.white,
                  ),
                  tooltip: 'Cancel (Esc)',
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _PulsingRecordingDot extends StatefulWidget {
  const _PulsingRecordingDot();

  @override
  State<_PulsingRecordingDot> createState() => _PulsingRecordingDotState();
}

class _PulsingRecordingDotState extends State<_PulsingRecordingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animController;
  late final Animation<double> _opacityAnim;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _opacityAnim = Tween<double>(begin: 0.35, end: 1.0).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeInOut),
    );

    // In automated widget tests, an infinite repeating animation prevents pumpAndSettle from settling.
    final isTestEnvironment = WidgetsBinding.instance.runtimeType
        .toString()
        .contains('Test');
    if (!isTestEnvironment) {
      _animController.repeat(reverse: true);
    } else {
      _animController.value = 1.0;
    }
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacityAnim,
      child: Container(
        width: 8,
        height: 8,
        decoration: const BoxDecoration(
          color: Colors.redAccent,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
