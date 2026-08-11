import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class ClipboardService {
  /// Copies a PNG file at [filePath] to the system clipboard across macOS, Windows, and Linux
  static Future<bool> copyImageToClipboard(String filePath) async {
    try {
      if (Platform.isMacOS) {
        final escapedPath = filePath.replaceAll('"', '\\"');
        final script = 'set the clipboard to (read (POSIX file "$escapedPath") as «class PNGf»)';
        final result = await Process.run('osascript', ['-e', script]);
        return result.exitCode == 0;
      } else if (Platform.isWindows) {
        final winPath = filePath.replaceAll('/', '\\').replaceAll('"', '\\"');
        final script = 'Add-Type -AssemblyName System.Windows.Forms,System.Drawing; [System.Windows.Forms.Clipboard]::SetImage([System.Drawing.Image]::FromFile("$winPath"))';
        final result = await Process.run('powershell', ['-NoProfile', '-Command', script]);
        return result.exitCode == 0;
      } else if (Platform.isLinux) {
        var result = await Process.run('xclip', ['-selection', 'clipboard', '-t', 'image/png', '-i', filePath]);
        if (result.exitCode != 0) {
          result = await Process.run('wl-copy', ['<', filePath]);
        }
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
