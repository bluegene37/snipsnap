// Gene - Nov, 13, 2026: Regression tests verifying video thumbnails and original backups are isolated from StorageService.loadHistory().
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:snipsnap/database/app_database.dart';
import 'package:snipsnap/services/capture_service.dart';
import 'package:snipsnap/services/database_service.dart';
import 'package:snipsnap/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'StorageService.loadHistory excludes .thumbnails, .originals, and rec_thumb_* files',
    () async {
      final tempDir = Directory.systemTemp.createTempSync(
        'snipsnap_thumb_isolation',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => tempDir.path,
          );

      final db = AppDatabase(NativeDatabase.memory());
      DatabaseService.db = db;
      addTearDown(() async {
        await db.close();
      });

      final capturesDir = Directory(
        p.join(tempDir.path, 'SnipSnap', 'Captures'),
      )..createSync(recursive: true);
      final thumbsDir = Directory(p.join(capturesDir.path, '.thumbnails'))
        ..createSync(recursive: true);
      final originalsDir = Directory(p.join(capturesDir.path, '.originals'))
        ..createSync(recursive: true);

      final blank = img.Image(width: 64, height: 64);
      final pngBytes = img.encodePng(blank);

      // Real screenshot + real video
      final realSnip = File(p.join(capturesDir.path, 'snip_300.png'))
        ..writeAsBytesSync(pngBytes);
      final realVideo = File(p.join(capturesDir.path, 'rec_100.mp4'))
        ..writeAsBytesSync(const [0, 0, 0, 24, 102, 116, 121, 112]);

      // Thumbnails & backups that must never appear as standalone gallery captures
      // Gene - Nov, 13, 2026: Replaced single cascade operator with direct method call to satisfy avoid_single_cascade_in_expression_statements lint.
      // File(p.join(capturesDir.path, 'rec_thumb_100.png'))
      //   ..writeAsBytesSync(pngBytes);
      // File(p.join(thumbsDir.path, 'rec_thumb_200.png'))
      //   ..writeAsBytesSync(pngBytes);
      // File(p.join(originalsDir.path, 'rec_100.mp4'))
      //   ..writeAsBytesSync(const [0, 0, 0, 24, 102, 116, 121, 112]);
      File(p.join(capturesDir.path, 'rec_thumb_100.png'))
          .writeAsBytesSync(pngBytes);
      File(p.join(thumbsDir.path, 'rec_thumb_200.png'))
          .writeAsBytesSync(pngBytes);
      File(p.join(originalsDir.path, 'rec_100.mp4'))
          .writeAsBytesSync(const [0, 0, 0, 24, 102, 116, 121, 112]);

      final history = await StorageService.loadHistory();
      final paths = history.map((e) => e.filePath).toSet();

      expect(paths, contains(realSnip.path));
      expect(paths, contains(realVideo.path));
      expect(paths.length, 2);

      final service = CaptureService();
      final thumbPath = await service.generateNewThumbnailPath();
      final backupPath = await service.getOriginalBackupPath('rec_100');
      expect(thumbPath, startsWith(thumbsDir.path));
      expect(backupPath, startsWith(originalsDir.path));
    },
  );
}
