import 'package:flutter/material.dart';

import '../../utils/snip_theme.dart';

/// Dimmed, input-blocking progress cover for the canvas area.
///
/// `SnipTheme.scrim`, not a per-mode token: this dims whatever was on screen
/// the instant before, in both chrome modes, the same way a modal barrier
/// would. A per-mode token would flip polarity in dark mode (a light wash
/// instead of a dim) and risk the white spinner and caption vanishing against
/// it — see `SnipTheme.scrim`'s own doc comment.
///
/// `ColoredBox` is load-bearing beyond the colour: an opaque one takes the hit
/// test, so the canvas underneath cannot be drawn on while the operation runs.
class CanvasBusyOverlay extends StatelessWidget {
  const CanvasBusyOverlay({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: SnipTheme.scrim,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Colors.white),
            const SizedBox(height: 16),
            Text(
              message,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
