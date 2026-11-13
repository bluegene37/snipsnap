import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class ClipboardService {
  // Gene - Nov, 08, 2026: Added native MethodChannel for <5ms NSPasteboard / Win32 clipboard image copy, paste, and file copy without spawning osascript or powershell.exe.
  static const MethodChannel _channel = MethodChannel('snipsnap/capture');

  /// Copies in-memory PNG [bytes] directly to the system clipboard.
  static Future<bool> copyImageBytesToClipboard(Uint8List bytes) async {
    try {
      if (Platform.isMacOS || Platform.isWindows) {
        final ok = await _channel.invokeMethod<bool>('copyImageToClipboard', {
          'bytes': bytes,
        });
        if (ok == true) return true;
      }
    } on MissingPluginException catch (_) {
      // Fallback handled by file-based path when needed
    } catch (e) {
      debugPrint('SnipSnap native copyImageBytesToClipboard error: $e');
    }
    return false;
  }

  /// Copies a PNG file at [filePath] to the system clipboard across macOS, Windows, and Linux
  static Future<bool> copyImageToClipboard(String filePath) async {
    try {
      // Gene - Nov, 08, 2026: Try native channel first on macOS and Windows for instant clipboard copy; fall back to subprocess only on MissingPluginException.
      // Old implementation:
      // if (Platform.isMacOS) {
      //   final escapedPath = filePath.replaceAll('"', '\\"');
      //   final script =
      //       'set the clipboard to (read (POSIX file "$escapedPath") as «class PNGf»)';
      //   final result = await Process.run('osascript', ['-e', script]);
      //   return result.exitCode == 0;
      // } else if (Platform.isWindows) {
      //   final winPath = filePath.replaceAll('/', '\\').replaceAll('"', '\\"');
      //   final script =
      //       'Add-Type -AssemblyName System.Windows.Forms,System.Drawing; [System.Windows.Forms.Clipboard]::SetImage([System.Drawing.Image]::FromFile("$winPath"))';
      //   final result = await Process.run('powershell', [
      //     '-NoProfile',
      //     '-Sta',
      //     '-Command',
      //     script,
      //   ]);
      //   return result.exitCode == 0;
      // }
      if (Platform.isMacOS) {
        try {
          final ok = await _channel.invokeMethod<bool>('copyImageToClipboard', {
            'filePath': filePath,
          });
          if (ok != null) return ok;
        } on MissingPluginException catch (_) {}
        final escapedPath = filePath.replaceAll('"', '\\"');
        final script =
            'set the clipboard to (read (POSIX file "$escapedPath") as «class PNGf»)';
        final result = await Process.run('osascript', ['-e', script]);
        return result.exitCode == 0;
      } else if (Platform.isWindows) {
        try {
          final ok = await _channel.invokeMethod<bool>('copyImageToClipboard', {
            'filePath': filePath,
          });
          if (ok != null) return ok;
        } on MissingPluginException catch (_) {}
        final winPath = filePath.replaceAll('/', '\\').replaceAll('"', '\\"');
        final script =
            'Add-Type -AssemblyName System.Windows.Forms,System.Drawing; [System.Windows.Forms.Clipboard]::SetImage([System.Drawing.Image]::FromFile("$winPath"))';
        // `-Sta`: the clipboard APIs need a single-threaded apartment, and
        // without it the copy throws instead of copying.
        final result = await Process.run('powershell', [
          '-NoProfile',
          '-Sta',
          '-Command',
          script,
        ]);
        return result.exitCode == 0;
      } else if (Platform.isLinux) {
        final result = await Process.run('xclip', [
          '-selection',
          'clipboard',
          '-t',
          'image/png',
          '-i',
          filePath,
        ]);
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

  // Gene - Nov, 08, 2026: Added pasteImageFromClipboard and copyFileToClipboard for Cmd/Ctrl+V image paste and MP4 video file copy.
  /// Reads an image from the system clipboard and writes it as a PNG to [targetPath].
  /// Returns [targetPath] if an image was found and saved, or null otherwise.
  static Future<String?> pasteImageFromClipboard(String targetPath) async {
    try {
      if (Platform.isMacOS || Platform.isWindows) {
        final savedPath = await _channel.invokeMethod<String?>(
          'pasteImageFromClipboard',
          {'targetPath': targetPath},
        );
        if (savedPath != null &&
            await File(savedPath).exists() &&
            await File(savedPath).length() > 0) {
          return savedPath;
        }
      }
    } on MissingPluginException catch (_) {
      // Fallback below
    } catch (e) {
      debugPrint('SnipSnap pasteImageFromClipboard error: $e');
    }
    return null;
  }

  /// Copies a file URL (such as an `.mp4` screen recording) to the system clipboard.
  static Future<bool> copyFileToClipboard(String filePath) async {
    try {
      if (Platform.isMacOS || Platform.isWindows) {
        final ok = await _channel.invokeMethod<bool>('copyFileToClipboard', {
          'filePath': filePath,
        });
        if (ok == true) return true;
      }
      await Clipboard.setData(ClipboardData(text: filePath));
      return true;
    } catch (e) {
      debugPrint('SnipSnap copyFileToClipboard error: $e');
      return false;
    }
  }
}
