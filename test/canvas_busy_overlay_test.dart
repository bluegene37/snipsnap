// Covers the progress cover shown over the canvas while crop, flatten, export
// and copy do their render -> decode -> encode work. Before it existed those
// operations gave no feedback at all: the canvas sat unchanged for what
// `_handleApplyCrop` calls "seconds of work on a large capture", and then the
// result appeared all at once, which reads as a dead button followed by an
// unexplained jump.
//
// `MainScreen` cannot be pumped in a widget test — it builds an `EditorCanvas`,
// which emits `Image.file`, which hangs `flutter_tester` (see the note in
// `main_screen_color_scheme_test.dart`). So the overlay is a component and this
// tests it directly.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/components/canvas_busy_overlay.dart';

void main() {
  testWidgets('shows a spinner and the caption it was given', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: CanvasBusyOverlay(message: 'Cropping…')),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Cropping…'), findsOneWidget);
  });

  testWidgets('swallows taps aimed at the canvas underneath', (tester) async {
    // The overlay does not cover the header, so a user can still reach Save or
    // Copy mid-crop — `_runBusy` drops re-entrant calls for that. What this
    // guards is the canvas itself: drawing onto a bitmap that is being
    // rewritten under you is the corruption case.
    var tapsThrough = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => tapsThrough++,
                ),
              ),
              const Positioned.fill(
                child: CanvasBusyOverlay(message: 'Saving…'),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tapAt(const Offset(40, 40));
    await tester.pump();

    expect(tapsThrough, 0);
  });

  testWidgets('stays legible in both chrome modes', (tester) async {
    // The scrim is a fixed dim rather than a per-mode token precisely so the
    // white spinner and caption never sit on a light wash. Pump under each
    // mode's surface to prove the caption is not painted mode-dependently.
    for (final mode in SnipThemeMode.values) {
      final theme = SnipTheme.forMode(mode);
      await tester.pumpWidget(
        SnipThemeScope(
          theme: theme,
          child: MaterialApp(
            home: Scaffold(
              backgroundColor: theme.surface,
              body: const CanvasBusyOverlay(message: 'Flattening…'),
            ),
          ),
        ),
      );

      final caption = tester.widget<Text>(find.text('Flattening…'));
      expect(caption.style?.color, Colors.white,
          reason: 'caption must stay white against the fixed scrim in $mode');
    }
  });
}
