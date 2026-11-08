// Gene - Nov, 08, 2026: Widget tests for VideoCapturePlayerView in light and dark SnipTheme.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/models/capture_item.dart';
import 'package:snipsnap/services/capture_service.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/video_capture_player_view.dart';

class _NoopVideoCaptureService extends CaptureService {
  @override
  Future<String?> extractVideoFrame({
    required String videoPath,
    required int timestampMs,
    required String targetPath,
  }) async {
    return null;
  }
}

void main() {
  for (final theme in [SnipTheme.light(), SnipTheme.dark()]) {
    final modeName = theme.isDark ? 'dark' : 'light';
    testWidgets(
      'VideoCapturePlayerView renders transport, trim, and export actions in $modeName mode',
      (tester) async {
        int? grabbedMs;
        (int, int)? trimmedRange;
        int copyCalls = 0;
        int saveCalls = 0;
        int revealCalls = 0;

        final item = CaptureItem(
          id: 'vid_1',
          filePath: '/nonexistent/demo_recording.mp4',
          title: 'Demo Recording',
          createdAt: DateTime(2026, 11, 8, 12, 0),
          width: 1920,
          height: 1080,
          mediaType: CaptureMediaType.video,
          durationMs: 12000,
          hasAudio: true,
        );

        await tester.pumpWidget(
          SnipThemeScope(
            theme: theme,
            child: MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 1100,
                  height: 760,
                  child: VideoCapturePlayerView(
                    capture: item,
                    captureService: _NoopVideoCaptureService(),
                    onGrabFrameAsScreenshot: (ms) async {
                      grabbedMs = ms;
                    },
                    onTrimVideo: (start, end) async {
                      trimmedRange = (start, end);
                    },
                    onCopyVideo: () => copyCalls++,
                    onSaveVideoAs: () => saveCalls++,
                    onRevealInFolder: () => revealCalls++,
                  ),
                ),
              ),
            ),
          ),
        );

        expect(find.text('Demo Recording'), findsWidgets);
        expect(find.textContaining('1920×1080'), findsWidgets);
        expect(find.text('1.0x'), findsOneWidget);

        // Toggle Trim bar
        await tester.tap(find.text('Trim'));
        await tester.pump();
        expect(find.text('Save Trimmed Clip'), findsOneWidget);

        await tester.tap(find.text('Save Trimmed Clip'));
        await tester.pump();
        expect(trimmedRange, equals((0, 12000)));

        // Grab frame as screenshot
        await tester.tap(find.text('Grab Frame as Screenshot'));
        await tester.pump();
        expect(grabbedMs, isNotNull);

        // Copy MP4, Save MP4 As, Folder
        await tester.tap(find.text('Copy MP4'));
        await tester.tap(find.text('Save MP4 As\u2026'));
        await tester.tap(find.text('Folder'));
        await tester.pump();

        expect(copyCalls, 1);
        expect(saveCalls, 1);
        expect(revealCalls, 1);
      },
    );
  }
}
