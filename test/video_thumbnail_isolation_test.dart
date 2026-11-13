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

  // Gene - Nov, 13, 2026: Verify StorageService.loadHistory ignores unfinalized AVAssetWriter MP4s (mdat size=0, no moov) while adopting finalized MP4s.
  test(
    'StorageService.loadHistory skips unfinalized AVAssetWriter MP4 files and adopts finalized MP4 files',
    () async {
      final tempDir = Directory.systemTemp.createTempSync(
        'snipsnap_unfinalized_mp4',
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

      // Build unfinalized MP4: 28-byte ftyp + 8-byte wide + 8-byte mdat(size=0) + 16 payload bytes, no moov
      final unfinalizedBytes = <int>[
        0, 0, 0, 28, ...'ftyp'.codeUnits, ...List<int>.filled(20, 0),
        0, 0, 0, 8, ...'wide'.codeUnits,
        0, 0, 0, 0, ...'mdat'.codeUnits,
        ...List<int>.filled(16, 0xAA),
      ];
      final unfinalizedFile = File(
        p.join(capturesDir.path, 'rec_unfinalized.mp4'),
      )..writeAsBytesSync(unfinalizedBytes);

      // Build finalized MP4: 28-byte ftyp + 24-byte mdat + 16-byte moov
      final finalizedBytes = <int>[
        0, 0, 0, 28, ...'ftyp'.codeUnits, ...List<int>.filled(20, 0),
        0, 0, 0, 24, ...'mdat'.codeUnits, ...List<int>.filled(16, 0xBB),
        0, 0, 0, 16, ...'moov'.codeUnits, ...List<int>.filled(8, 0),
      ];
      final finalizedFile = File(p.join(capturesDir.path, 'rec_finalized.mp4'))
        ..writeAsBytesSync(finalizedBytes);

      final history = await StorageService.loadHistory();
      final paths = history.map((e) => e.filePath).toSet();

      expect(paths, isNot(contains(unfinalizedFile.path)));
      expect(paths, contains(finalizedFile.path));
      expect(paths.length, 1);
    },
  );
}
