import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class CaptureService {
  /// Gets the directory where captures are stored
  Future<Directory> getStorageDirectory() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final snapDir = Directory(p.join(docsDir.path, 'SnipSnap', 'Captures'));
    if (!await snapDir.exists()) {
      await snapDir.create(recursive: true);
    }
    return snapDir;
  }

  /// Generates a new file path for a screenshot
  Future<String> _generateNewPath() async {
    final dir = await getStorageDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return p.join(dir.path, 'snap_$timestamp.png');
  }

  /// Perform interactive area capture using native macOS screencapture
  Future<String?> captureInteractive() async {
    final targetPath = await _generateNewPath();
    try {
      if (Platform.isMacOS) {
        final result = await Process.run('/usr/sbin/screencapture', ['-i', targetPath]);
        if (result.exitCode == 0 && await File(targetPath).exists()) {
          final file = File(targetPath);
          if (await file.length() > 0) {
            return targetPath;
          }
        }
      }
    } catch (e) {
      debugPrint('SnipSnap capture error: $e');
    }
    return null;
  }

  /// Perform full screen capture
  Future<String?> captureFullScreen() async {
    final targetPath = await _generateNewPath();
    try {
      if (Platform.isMacOS) {
        final result = await Process.run('/usr/sbin/screencapture', [targetPath]);
        if (result.exitCode == 0 && await File(targetPath).exists()) {
          return targetPath;
        }
      }
    } catch (e) {
      debugPrint('SnipSnap capture error: $e');
    }
    return null;
  }

  /// Perform delayed capture with countdown
  Future<String?> captureTimer(int seconds) async {
    final targetPath = await _generateNewPath();
    try {
      if (Platform.isMacOS) {
        final result = await Process.run('/usr/sbin/screencapture', ['-T', '$seconds', '-i', targetPath]);
        if (result.exitCode == 0 && await File(targetPath).exists()) {
          return targetPath;
        }
      }
    } catch (e) {
      debugPrint('SnipSnap capture error: $e');
    }
    return null;
  }

  /// Copy external image file into SnipSnap capture library
  Future<String?> importImage(String sourcePath) async {
    final targetPath = await _generateNewPath();
    try {
      final sourceFile = File(sourcePath);
      if (await sourceFile.exists()) {
        await sourceFile.copy(targetPath);
        return targetPath;
      }
    } catch (e) {
      debugPrint('SnipSnap capture error: $e');
    }
    return null;
  }
}
