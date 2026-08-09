import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/capture_item.dart';

import 'database_service.dart';

class StorageService {
  /// Save image bytes to a custom location chosen by the user
  static Future<String?> exportImageDialog(List<int> bytes, String defaultName) async {
    try {
      final result = await FilePicker.saveFile(
        dialogTitle: 'Save Screenshot As',
        fileName: defaultName.endsWith('.png') ? defaultName : '$defaultName.png',
        type: FileType.custom,
        allowedExtensions: ['png', 'jpg', 'jpeg'],
      );

      if (result != null) {
        final file = File(result);
        await file.writeAsBytes(bytes);
        return result;
      }
    } catch (_) {}
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
        final files = snapDir.listSync();
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
    } catch (_) {}
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
}
