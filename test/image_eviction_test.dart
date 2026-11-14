// Gene - Nov, 14, 2026: Added unit tests for evictImageFileFromCaches and kGalleryThumbnailCacheWidth.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snipsnap/utils/image_eviction.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ui.Image sourceImage;

  setUp(() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    sourceImage = await createTestImage(width: 16, height: 16, cache: false);
  });

  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    sourceImage.dispose();
  });

  Future<Object> seedProvider(ImageProvider<Object> provider) async {
    final Object key = await provider.obtainKey(ImageConfiguration.empty);
    PaintingBinding.instance.imageCache.putIfAbsent(
      key,
      () => OneFrameImageStreamCompleter(
        SynchronousFuture<ImageInfo>(ImageInfo(image: sourceImage.clone())),
      ),
    );
    return key;
  }

  test('kGalleryThumbnailCacheWidth matches gallery thumbnail decode width', () {
    expect(kGalleryThumbnailCacheWidth, 360);
  });

  test(
    'evictImageFileFromCaches removes both full-res FileImage and gallery ResizeImage entries',
    () async {
      const targetPath = '/tmp/snipsnap_capture_a.png';
      final fullProvider = FileImage(File(targetPath));
      final thumbProvider = ResizeImage.resizeIfNeeded(
        kGalleryThumbnailCacheWidth,
        null,
        FileImage(File(targetPath)),
      );

      final fullKey = await seedProvider(fullProvider);
      final thumbKey = await seedProvider(thumbProvider);

      final cache = PaintingBinding.instance.imageCache;
      expect(cache.containsKey(fullKey), isTrue);
      expect(cache.containsKey(thumbKey), isTrue);

      await evictImageFileFromCaches(targetPath);

      expect(cache.containsKey(fullKey), isFalse);
      expect(cache.containsKey(thumbKey), isFalse);
    },
  );

  test(
    'evictImageFileFromCaches leaves unrelated cached capture paths intact',
    () async {
      const targetPath = '/tmp/snipsnap_capture_a.png';
      const otherPath = '/tmp/snipsnap_capture_b.png';

      final targetFullKey = await seedProvider(FileImage(File(targetPath)));
      final targetThumbKey = await seedProvider(
        ResizeImage.resizeIfNeeded(
          kGalleryThumbnailCacheWidth,
          null,
          FileImage(File(targetPath)),
        ),
      );
      final otherFullKey = await seedProvider(FileImage(File(otherPath)));
      final otherThumbKey = await seedProvider(
        ResizeImage.resizeIfNeeded(
          kGalleryThumbnailCacheWidth,
          null,
          FileImage(File(otherPath)),
        ),
      );

      await evictImageFileFromCaches(targetPath);

      final cache = PaintingBinding.instance.imageCache;
      expect(cache.containsKey(targetFullKey), isFalse);
      expect(cache.containsKey(targetThumbKey), isFalse);
      expect(cache.containsKey(otherFullKey), isTrue);
      expect(cache.containsKey(otherThumbKey), isTrue);
    },
  );

  test(
    'evictImageFileFromCaches completes cleanly when target path is uncached',
    () async {
      const otherPath = '/tmp/snipsnap_capture_b.png';
      final otherFullKey = await seedProvider(FileImage(File(otherPath)));

      await evictImageFileFromCaches('/tmp/snipsnap_uncached.png');

      expect(
        PaintingBinding.instance.imageCache.containsKey(otherFullKey),
        isTrue,
      );
    },
  );
}
