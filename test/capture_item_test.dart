import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/models/capture_item.dart';

void main() {
  test('hasDimensions is false when width or height is zero', () {
    final item = CaptureItem(
      id: 'a',
      filePath: '/tmp/a.png',
      title: 'A',
      createdAt: DateTime(2026, 1, 1),
    );
    expect(item.hasDimensions, isFalse);

    expect(item.copyWith(width: 100).hasDimensions, isFalse);
    expect(item.copyWith(width: 100, height: 50).hasDimensions, isTrue);
  });

  // Gene - Oct, 27, 2026: Added unit tests for video recording fields on CaptureItem.
  test('CaptureItem supports video media type, duration, audio and thumbnail metadata', () {
    final defaultItem = CaptureItem(
      id: 'img1',
      filePath: '/tmp/snap.png',
      title: 'Snap',
      createdAt: DateTime(2026, 10, 27),
    );
    expect(defaultItem.mediaType, CaptureMediaType.image);
    expect(defaultItem.isImage, isTrue);
    expect(defaultItem.isVideo, isFalse);
    expect(defaultItem.durationMs, 0);
    expect(defaultItem.hasAudio, isFalse);
    expect(defaultItem.thumbnailPath, isNull);

    final videoItem = CaptureItem(
      id: 'vid1',
      filePath: '/tmp/record.mp4',
      title: 'Screen Recording',
      createdAt: DateTime(2026, 10, 27),
      width: 1920,
      height: 1080,
      mediaType: CaptureMediaType.video,
      durationMs: 15400,
      hasAudio: true,
      thumbnailPath: '/tmp/thumb.png',
    );
    expect(videoItem.mediaType, CaptureMediaType.video);
    expect(videoItem.isVideo, isTrue);
    expect(videoItem.isImage, isFalse);
    expect(videoItem.durationMs, 15400);
    expect(videoItem.hasAudio, isTrue);
    expect(videoItem.thumbnailPath, '/tmp/thumb.png');

    final json = videoItem.toJson();
    expect(json['mediaType'], 'video');
    expect(json['durationMs'], 15400);
    expect(json['hasAudio'], isTrue);
    expect(json['thumbnailPath'], '/tmp/thumb.png');

    final restored = CaptureItem.fromJson(json);
    expect(restored.mediaType, CaptureMediaType.video);
    expect(restored.isVideo, isTrue);
    expect(restored.durationMs, 15400);
    expect(restored.hasAudio, isTrue);
    expect(restored.thumbnailPath, '/tmp/thumb.png');

    final updated = restored.copyWith(durationMs: 20000, hasAudio: false);
    expect(updated.durationMs, 20000);
    expect(updated.hasAudio, isFalse);
    expect(updated.isVideo, isTrue);
  });
}
