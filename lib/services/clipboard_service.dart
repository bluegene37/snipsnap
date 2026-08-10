import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class ClipboardService {
  /// Copies a PNG file at [filePath] to the system clipboard (macOS native image clipboard support)
  static Future<bool> copyImageToClipboard(String filePath) async {
    try {
      if (Platform.isMacOS) {
        final escapedPath = filePath.replaceAll('"', '\\"');
        final script = 'set the clipboard to (read (POSIX file "$escapedPath") as «class PNGf»)';
        final result = await Process.run('osascript', ['-e', script]);
        return result.exitCode == 0;
      } else {
        await Clipboard.setData(ClipboardData(text: filePath));
        return true;
      }
    } catch (e) {
      debugPrint('SnipSnap clipboard error: $e');
      return false;
    }
  }

  /// Copy text to clipboard
  static Future<void> copyText(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }
}
