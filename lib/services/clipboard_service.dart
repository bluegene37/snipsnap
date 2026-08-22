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
        final result = await Process.run(
            'xclip', ['-selection', 'clipboard', '-t', 'image/png', '-i', filePath]);
        if (result.exitCode == 0) return true;

        // Wayland fallback. `wl-copy` reads the image from stdin, so the file
        // has to be piped in: passing `['<', filePath]` to `Process.run` — as
        // this did — hands `wl-copy` two literal arguments, since there is no
        // shell to interpret the redirect, and it copies nothing.
        try {
          final proc = await Process.start('wl-copy', ['--type', 'image/png']);
          proc.stdin.add(await File(filePath).readAsBytes());
          await proc.stdin.close();
          return await proc.exitCode == 0;
        } catch (e) {
          debugPrint('SnipSnap wl-copy error: $e');
          return false;
        }
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
