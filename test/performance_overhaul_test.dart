// Gene - Nov, 20, 2026: Unit tests covering Phase 1 performance optimizations (ThemeData memoization, scoped DB pagination queries, batched annotation writes, and RGBA8/RGB8 scanline flood fill).
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:snipsnap/database/app_database.dart';
import 'package:snipsnap/services/database_service.dart';
import 'package:snipsnap/utils/canvas_projection.dart';
import 'package:snipsnap/utils/constants.dart';
import 'package:snipsnap/utils/image_operations.dart';
import 'package:snipsnap/utils/snip_theme.dart';
import 'package:snipsnap/views/main_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('ThemeData memoization', () {
    test('snipThemeData returns cached instance for identical theme', () {
      final dark = SnipTheme.forMode(SnipThemeMode.dark);
      final light = SnipTheme.forMode(SnipThemeMode.light);

      final d1 = snipThemeData(dark);
      final d2 = snipThemeData(dark);
      final l1 = snipThemeData(light);
      final l2 = snipThemeData(light);

      expect(identical(d1, d2), isTrue);
      expect(identical(l1, l2), isTrue);
      expect(identical(d1, l1), isFalse);
    });
  });

  group('Scoped & batched DB queries', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      DatabaseService.db = db;
    });

    tearDown(() async {
      await db.close();
    });

    test(
      'getAnnotationsForCaptureIds only returns rows for requested captures',
      () async {
        final now = DateTime(2026, 11, 20, 12, 0);
        for (var i = 1; i <= 3; i++) {
          await db.insertOrUpdateCapture(
            CapturesCompanion(
              id: Value('c$i'),
              filePath: Value('/tmp/c$i.png'),
              title: Value('Capture $i'),
              createdAt: Value(now.add(Duration(minutes: i))),
              width: const Value(100),
              height: const Value(100),
              thumbnailPath: Value(i == 2 ? '/tmp/thumb_2.png' : null),
            ),
          );
          await db.saveAnnotationsForCapture('c$i', [
            AnnotationsCompanion(
              id: Value('a${i}_1'),
              captureId: Value('c$i'),
              tool: Value(CanvasTool.pen.name),
              color: const Value(0xFFFF0000),
              strokeWidth: const Value(2.0),
              fontSize: const Value(14.0),
              createdAt: Value(now),
              zIndex: const Value(0),
              coordSpace: Value(CoordSpace.imagePixels.name),
            ),
            AnnotationsCompanion(
              id: Value('a${i}_2'),
              captureId: Value('c$i'),
              tool: Value(CanvasTool.arrow.name),
              color: const Value(0xFF00FF00),
              strokeWidth: const Value(3.0),
              fontSize: const Value(14.0),
              createdAt: Value(now),
              zIndex: const Value(1),
              coordSpace: Value(CoordSpace.imagePixels.name),
            ),
          ]);
        }

        final scoped = await db.getAnnotationsForCaptureIds(['c1', 'c3']);
        expect(
          scoped.map((a) => a.id),
          unorderedEquals(['a1_1', 'a1_2', 'a3_1', 'a3_2']),
        );
        final c1Anns = scoped
            .where((a) => a.captureId == 'c1')
            .map((a) => a.id);
        expect(c1Anns, ['a1_1', 'a1_2']);

        final paged = await DatabaseService.loadCapturesFromDb(
          limit: 2,
          offset: 0,
        );
        expect(paged.map((c) => c.id), ['c3', 'c2']);
        expect(paged.first.annotations.map((a) => a.id), ['a3_1', 'a3_2']);

        final paths = await db.getAllCapturePathsAndThumbnails();
        expect(paths.length, 3);
        expect(paths.map((p) => p.filePath), contains('/tmp/c2.png'));
        expect(
          paths.where((p) => p.thumbnailPath == '/tmp/thumb_2.png').length,
          1,
        );

        final known = await DatabaseService.loadKnownCapturePaths();
        expect(known.filePaths, {'/tmp/c1.png', '/tmp/c2.png', '/tmp/c3.png'});
        expect(known.thumbnailPaths, {'/tmp/thumb_2.png'});
      },
    );
  });

  group('Scanline ImageOperations.floodFill', () {
    test('fills U-shaped non-convex 4-connected region accurately', () {
      // 7x5 RGBA image with a white U-shaped corridor surrounded by black walls.
      final image = img.Image(width: 7, height: 5, numChannels: 4);
      img.fill(image, color: img.ColorRgba8(0, 0, 0, 255));
      for (final pt in [
        (1, 1), (1, 2), (1, 3), // left arm
        (2, 3), (3, 3), (4, 3), // bottom bar
        (5, 3), (5, 2), (5, 1), // right arm
      ]) {
        image.setPixelRgba(pt.$1, pt.$2, 255, 255, 255, 255);
      }

      final changed = ImageOperations.floodFill(
        image: image,
        startX: 1,
        startY: 1,
        fillColor: const Color(0xFF10B981),
        tolerancePercent: 5.0,
      );
      expect(changed, isTrue);

      for (final pt in [
        (1, 1),
        (1, 2),
        (1, 3),
        (2, 3),
        (3, 3),
        (4, 3),
        (5, 3),
        (5, 2),
        (5, 1),
      ]) {
        final p = image.getPixel(pt.$1, pt.$2);
        expect([p.r, p.g, p.b, p.a], [0x10, 0xB9, 0x81, 255]);
      }
      // Walls stayed black.
      expect(image.getPixel(3, 1).r, 0);
      expect(image.getPixel(0, 0).r, 0);
    });

    test('fills RGB8 (3-channel) U-shaped and global images fast', () {
      final image = img.Image(width: 64, height: 64, numChannels: 3);
      img.fill(image, color: img.ColorRgb8(240, 240, 240));
      // Vertical black wall splitting image into left and right halves
      for (int y = 0; y < 64; y++) {
        image.setPixelRgb(32, y, 0, 0, 0);
      }

      final changed = ImageOperations.floodFill(
        image: image,
        startX: 5,
        startY: 5,
        fillColor: const Color(0xFFFF0000),
        tolerancePercent: 2.0,
      );
      expect(changed, isTrue);
      expect(image.getPixel(10, 50).r, 255);
      expect(image.getPixel(10, 50).g, 0);
      // Right side stayed light grey
      expect(image.getPixel(45, 50).r, 240);

      // Global fill reaches the right side too
      final globalChanged = ImageOperations.floodFill(
        image: image,
        startX: 45,
        startY: 50,
        fillColor: const Color(0xFF0000FF),
        tolerancePercent: 2.0,
        isGlobal: true,
      );
      expect(globalChanged, isTrue);
      expect(image.getPixel(60, 10).b, 255);
      expect(image.getPixel(60, 10).r, 0);
    });
  });
}
