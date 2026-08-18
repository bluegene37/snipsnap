import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/capture_item.dart';

import 'database_service.dart';

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
    final targetFileName = cleanName.toLowerCase().endsWith('.$ext') ? cleanName : '$cleanName.$ext';

    List<int> bytesToSave = bytes;

    if (isJpg) {
      try {
        final decoded = img.decodeImage(Uint8List.fromList(bytes));
        if (decoded != null) {
          bytesToSave = img.encodeJpg(decoded, quality: jpgQuality);
        }
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
          final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
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

  /// Save image bytes to a custom location chosen by the user (defaults to Downloads directory)
  static Future<String?> exportImageDialog(List<int> bytes, String defaultName) async {
    return exportImageDialogWithFormat(bytes: bytes, fileName: defaultName, isJpg: false);
  }

  /// Direct save to user's Downloads folder
  static Future<String?> saveToDownloads(List<int> bytes, String defaultName) async {
    try {
      final downloadsDir = await getDownloadsDirectory();
      if (downloadsDir != null) {
        final fileName = defaultName.endsWith('.png') ? defaultName : '$defaultName.png';
        final targetPath = p.join(downloadsDir.path, fileName);
        final file = File(targetPath);
        await file.writeAsBytes(bytes);
        return targetPath;
      }
    } catch (e) {
      debugPrint('SnipSnap storage error: $e');
    }
    return null;
  }

  /// Write image bytes to temporary or cache file
  static Future<String> saveTempImage(List<int> bytes) async {
    final tempDir = await Directory.systemTemp.createTemp('snipsnap_');
    final file = File(p.join(tempDir.path, 'edited_${DateTime.now().millisecondsSinceEpoch}.png'));
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
          if (f is File && (f.path.endsWith('.png') || f.path.endsWith('.jpg') || f.path.endsWith('.jpeg'))) {
            if (!existingPaths.contains(f.path)) {
              final stat = await f.stat();
              final newItem = CaptureItem(
                id: stat.modified.millisecondsSinceEpoch.toString(),
                filePath: f.path,
                title: 'Snap ${stat.modified.hour.toString().padLeft(2, '0')}:${stat.modified.minute.toString().padLeft(2, '0')}:${stat.modified.second.toString().padLeft(2, '0')}',
                createdAt: stat.modified,
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
        final result = await Process.run('explorer.exe', [folderPath.replaceAll('/', '\\')]);
        return result.exitCode == 0;
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
        final result = await Process.run('explorer.exe', ['/select,', filePath.replaceAll('/', '\\')]);
        return result.exitCode == 0;
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
