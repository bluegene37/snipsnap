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

// Gene - Nov, 13, 2026: Fake native player CaptureService for testing Texture rendering and audio mute controls.
class _FakeTextureVideoCaptureService extends CaptureService {
  bool? lastMuted;
  int disposedTextureId = -1;

  @override
  Future<NativeVideoPlayerInfo?> createVideoPlayer(String videoPath) async {
    return const NativeVideoPlayerInfo(
      textureId: 7,
      durationMs: 12000,
      width: 1920,
      height: 1080,
      hasAudio: true,
    );
  }

  @override
  Future<void> setVideoMuted(int textureId, bool muted) async {
    lastMuted = muted;
  }

  @override
  Future<void> disposeVideoPlayer(int textureId) async {
    disposedTextureId = textureId;
  }

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

  // Gene - Nov, 13, 2026: Added tests for Cut Selection, Save Copy, Undo Edit, inline Export GIF bar, native Texture rendering, and mute toggle.
  testWidgets(
    'VideoCapturePlayerView supports Cut Selection, Save Copy, Undo Edit, GIF export, Texture, and mute',
    (tester) async {
      final fakeService = _FakeTextureVideoCaptureService();
      int restoreCalls = 0;
      ({int startMs, int endMs, int fps, int maxWidth, bool copy})? gifExport;

      final item = CaptureItem(
        id: 'vid_2',
        filePath: '/nonexistent/demo_recording.mp4',
        title: 'Snagit Flow Demo',
        createdAt: DateTime(2026, 11, 13, 12, 0),
        width: 1920,
        height: 1080,
        mediaType: CaptureMediaType.video,
        durationMs: 12000,
        hasAudio: true,
      );

      await tester.pumpWidget(
        SnipThemeScope(
          theme: SnipTheme.light(),
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 1200,
                height: 820,
                child: VideoCapturePlayerView(
                  capture: item,
                  captureService: fakeService,
                  onGrabFrameAsScreenshot: (_) async {},
                  onTrimVideo: (_, _) async {},
                  onCutVideo: (_, _) async {},
                  onSaveTrimmedCopy: (_, _) async {},
                  canRestoreOriginal: true,
                  onRestoreOriginal: () async {
                    restoreCalls++;
                  },
                  onExportGif: ({
                    required int startMs,
                    required int endMs,
                    required int fps,
                    required int maxWidth,
                    required bool copyToClipboard,
                  }) async {
                    gifExport = (
                      startMs: startMs,
                      endMs: endMs,
                      fps: fps,
                      maxWidth: maxWidth,
                      copy: copyToClipboard,
                    );
                  },
                  onCopyVideo: () {},
                  onSaveVideoAs: () {},
                  onRevealInFolder: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Native Texture rendered and Mute button toggles native mute
      expect(find.byType(Texture), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('video-mute-btn')));
      await tester.pump();
      expect(fakeService.lastMuted, isTrue);

      // Trim bar reveals Cut Selection and Save Copy
      await tester.tap(find.text('Trim'));
      await tester.pump();
      expect(find.text('Cut Selection'), findsOneWidget);
      expect(find.text('Save Copy'), findsOneWidget);

      // Undo Edit visible when canRestoreOriginal is true
      expect(find.text('Undo Edit'), findsOneWidget);
      await tester.tap(find.text('Undo Edit'));
      await tester.pump();
      expect(restoreCalls, 1);

      // Inline Export GIF bar
      await tester.tap(find.text('Export GIF'));
      await tester.pump();
      expect(find.text('10 FPS'), findsOneWidget);
      expect(find.text('15 FPS'), findsOneWidget);
      expect(find.text('20 FPS'), findsOneWidget);
      expect(find.text('Save GIF As\u2026'), findsOneWidget);
      expect(find.text('Copy GIF'), findsOneWidget);

      await tester.tap(find.text('20 FPS'));
      await tester.tap(find.text('Copy GIF'));
      await tester.pump();
      expect(gifExport, isNotNull);
      expect(gifExport!.fps, 20);
      expect(gifExport!.copy, isTrue);
    },
  );
}
