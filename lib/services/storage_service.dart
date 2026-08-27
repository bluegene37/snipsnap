import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/capture_item.dart';

import 'database_service.dart';

/// `compute` entry point for the JPEG export transcode. Top-level because a
/// closure or instance method cannot cross an isolate boundary. Falls back to
/// the original bytes when the source will not decode, so a save never fails
/// outright on a format the `image` package cannot read.
Uint8List _transcodeToJpg(({Uint8List bytes, int quality}) req) {
  final decoded = img.decodeImage(req.bytes);
  if (decoded == null) return req.bytes;
  return Uint8List.fromList(img.encodeJpg(decoded, quality: req.quality));
}

class StorageService {
  /// Save image bytes with specific format (.png or .jpg) to user selected location
  static Future<String?> exportImageDialogWithFormat({
    required List<int> bytes,
    required String fileName,
    required bool isJpg,
    int jpgQuality = 90,
    String? customFolderPath,
  }) async {
    final ext = isJpg ? 'jpg' : 'png';
    String cleanName = fileName
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '-')
        .replaceAll(' ', '_')
        .trim();
    if (cleanName.isEmpty) cleanName = 'screenshot';
    final targetFileName = cleanName.toLowerCase().endsWith('.$ext')
        ? cleanName
        : '$cleanName.$ext';

    List<int> bytesToSave = bytes;

    if (isJpg) {
      try {
        // Decode + re-encode of a full-resolution capture, so it runs on a
        // worker isolate: on the UI isolate this blocked the frame that opened
        // the save dialog.
        bytesToSave = await compute(_transcodeToJpg, (
          bytes: Uint8List.fromList(bytes),
          quality: jpgQuality,
        ));
      } catch (e) {
        debugPrint('SnipSnap JPG encode error: $e');
      }
    }

    // Direct save if specific folder preset or custom directory is selected
    if (customFolderPath != null && customFolderPath.isNotEmpty) {
      try {
        Directory? targetDir;
        if (customFolderPath == 'downloads') {
          targetDir = await getDownloadsDirectory();
        } else if (customFolderPath == 'desktop') {
          final home =
              Platform.environment['HOME'] ??
              Platform.environment['USERPROFILE'];
          if (home != null) targetDir = Directory(p.join(home, 'Desktop'));
        } else if (customFolderPath == 'documents') {
          targetDir = await getApplicationDocumentsDirectory();
        } else {
          targetDir = Directory(customFolderPath);
        }

        if (targetDir != null && await targetDir.exists()) {
          final targetPath = p.join(targetDir.path, targetFileName);
          final file = File(targetPath);
          await file.writeAsBytes(bytesToSave);
          return targetPath;
        }
      } catch (e) {
        debugPrint('SnipSnap customFolderPath save error: $e');
      }
    }

    // 1. Try native save file dialog with target filename
    try {
      final savedUri = await FilePicker.saveFile(
        dialogTitle: 'Save Screenshot As',
        fileName: targetFileName,
        type: FileType.any,
        bytes: Uint8List.fromList(bytesToSave),
      );

      if (savedUri != null) {
        final finalPath = savedUri.toFilePath();
        return finalPath;
      }
    } catch (e) {
      debugPrint('SnipSnap FilePicker.saveFile primary error: $e');
    }

    // 2. Secondary fallback: Prompt user to choose target folder if saveFile fails or returns null
    try {
      final dirPath = await FilePicker.getDirectoryPath(
        dialogTitle: 'Select Folder to Save Screenshot',
      );
      if (dirPath != null && dirPath.trim().isNotEmpty) {
        final targetPath = p.join(dirPath, targetFileName);
        final file = File(targetPath);
        await file.writeAsBytes(bytesToSave);
        return targetPath;
      }
    } catch (e) {
      debugPrint('SnipSnap getDirectoryPath fallback error: $e');
    }

    // 3. Ultimate Fallback: Save directly to user's Downloads directory if native file pickers fail
    try {
      final downloadsDir = await getDownloadsDirectory();
      if (downloadsDir != null && downloadsDir.existsSync()) {
        final targetPath = p.join(downloadsDir.path, targetFileName);
        final file = File(targetPath);
        await file.writeAsBytes(bytesToSave);
        return targetPath;
      }
    } catch (e) {
      debugPrint('SnipSnap downloads directory fallback error: $e');
    }

    return null;
  }

  /// Write image bytes to temporary or cache file
  static Future<String> saveTempImage(List<int> bytes) async {
    final tempDir = await Directory.systemTemp.createTemp('snipsnap_');
    final file = File(
      p.join(
        tempDir.path,
        'edited_${DateTime.now().millisecondsSinceEpoch}.png',
      ),
    );
    await file.writeAsBytes(bytes);
    return file.path;
  }

  /// Load persistent capture history from Drift SQLite local database
  static Future<List<CaptureItem>> loadHistory() async {
    final items = <CaptureItem>[];
    try {
      final dbItems = await DatabaseService.loadCapturesFromDb();
      for (final item in dbItems) {
        if (await File(item.filePath).exists()) {
          items.add(item);
        }
      }

      // Also scan directory for any existing images not yet in Drift DB
      final docsDir = await getApplicationDocumentsDirectory();
      final snapDir = Directory(p.join(docsDir.path, 'SnipSnap', 'Captures'));
      if (await snapDir.exists()) {
        final existingPaths = items.map((i) => i.filePath).toSet();
        final files = await snapDir.list().toList();
        for (final f in files) {
          if (f is File &&
              (f.path.endsWith('.png') ||
                  f.path.endsWith('.jpg') ||
                  f.path.endsWith('.jpeg'))) {
            if (!existingPaths.contains(f.path)) {
              final stat = await f.stat();
              int w = 0;
              int h = 0;
              try {
                // Off the UI isolate, like every other decode in the app: this
                // loop runs at startup over every file in the library folder,
                // and a pure-Dart PNG decode of a Retina capture is long
                // enough to be seen as a freeze once there are a few of them.
                final decoded = await compute(
                  img.decodeImage,
                  await f.readAsBytes(),
                );
                if (decoded != null) {
                  w = decoded.width;
                  h = decoded.height;
                }
              } catch (e) {
                debugPrint('SnipSnap dimension read error: $e');
              }
              final newItem = CaptureItem(
                id: '${stat.modified.millisecondsSinceEpoch}_${p.basename(f.path)}',
                filePath: f.path,
                title:
                    'Snap ${stat.modified.hour.toString().padLeft(2, '0')}:${stat.modified.minute.toString().padLeft(2, '0')}:${stat.modified.second.toString().padLeft(2, '0')}',
                createdAt: stat.modified,
                width: w,
                height: h,
              );
              items.add(newItem);
              await DatabaseService.saveCaptureToDb(newItem);
            }
          }
        }
      }

      items.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } catch (e) {
      debugPrint('SnipSnap storage error: $e');
    }
    return items;
  }

  /// Save capture history to Drift SQLite local database
  static Future<void> saveHistory(List<CaptureItem> items) async {
    await DatabaseService.saveAllCapturesToDb(items);
  }

  /// Save single capture item to Drift SQLite local database
  static Future<void> saveCaptureItem(CaptureItem item) async {
    await DatabaseService.saveCaptureToDb(item);
  }

  /// Delete capture from Drift SQLite local database
  static Future<void> deleteCaptureItem(String id) async {
    await DatabaseService.deleteCaptureFromDb(id);
  }

  /// Returns the default screenshot captures library directory
  static Future<Directory> getLibraryDirectory() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final snapDir = Directory(p.join(docsDir.path, 'SnipSnap', 'Captures'));
    try {
      if (!await snapDir.exists()) {
        await snapDir.create(recursive: true);
      }
    } catch (e) {
      debugPrint('SnipSnap getLibraryDirectory create note: $e');
    }
    return snapDir;
  }

  /// Opens the screenshots library directory in the native file manager (Finder / Explorer / Files)
  static Future<bool> openLibraryFolder() async {
    try {
      final dir = await getLibraryDirectory();
      return await openFolder(dir.path);
    } catch (e) {
      debugPrint('SnipSnap openLibraryFolder error: $e');
      return false;
    }
  }

  /// Opens a folder path in the native file manager
  static Future<bool> openFolder(String folderPath) async {
    try {
      if (Platform.isMacOS) {
        final result = await Process.run('open', [folderPath]);
        return result.exitCode == 0;
      } else if (Platform.isWindows) {
        // Not gated on the exit code: `explorer.exe` routinely returns 1 even
        // when it opened the window, so checking it reported failure for a
        // folder the user was already looking at.
        await Process.run('explorer.exe', [folderPath.replaceAll('/', '\\')]);
        return true;
      } else if (Platform.isLinux) {
        final result = await Process.run('xdg-open', [folderPath]);
        return result.exitCode == 0;
      }
      return false;
    } catch (e) {
      debugPrint('SnipSnap openFolder error: $e');
      return false;
    }
  }

  /// Reveals/selects a specific file inside the native file manager
  static Future<bool> revealFileInFolder(String filePath) async {
    try {
      if (Platform.isMacOS) {
        final result = await Process.run('open', ['-R', filePath]);
        return result.exitCode == 0;
      } else if (Platform.isWindows) {
        // One argument, not two: `explorer /select,C:\path` is a single token
        // and splitting it left explorer opening Documents instead of
        // selecting the file. Exit code ignored for the reason above.
        await Process.run('explorer.exe', [
          '/select,${filePath.replaceAll('/', '\\')}',
        ]);
        return true;
      } else if (Platform.isLinux) {
        final dir = p.dirname(filePath);
        final result = await Process.run('xdg-open', [dir]);
        return result.exitCode == 0;
      }
      return false;
    } catch (e) {
      debugPrint('SnipSnap revealFileInFolder error: $e');
      return false;
    }
  }
}
