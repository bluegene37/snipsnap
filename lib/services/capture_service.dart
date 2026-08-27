import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class CaptureService {
  static const MethodChannel _channel = MethodChannel('snipsnap/capture');

  /// Gets the directory where captures are stored
  Future<Directory> getStorageDirectory() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final snapDir = Directory(p.join(docsDir.path, 'SnipSnap', 'Captures'));
    if (!await snapDir.exists()) {
      await snapDir.create(recursive: true);
    }
    return snapDir;
  }

  /// Whether the OS will actually let this app see the screen.
  ///
  /// macOS grants Screen Recording per app, and a missing grant does not fail
  /// loudly: the capture succeeds and comes back showing only the desktop
  /// wallpaper. Asking first is the only way to tell the difference between
  /// "the user captured an empty desktop" and "the system refused us".
  ///
  /// True on platforms with no such gate, and true when the plugin is absent,
  /// so the `screencapture` fallback path is never blocked by this check.
  Future<bool> hasScreenCapturePermission() async {
    if (!Platform.isMacOS) return true;
    try {
      return await _channel.invokeMethod<bool>('screenCaptureAuthorized') ??
          true;
    } on MissingPluginException catch (_) {
      return true;
    } catch (e) {
      debugPrint('SnipSnap permission check error: $e');
      return true;
    }
  }

  /// Returns [path] when it names a file with actual pixels in it, deleting it
  /// and returning null otherwise.
  ///
  /// A cancelled or refused capture routinely leaves a zero-byte file behind
  /// while the tool still exits 0, and `StorageService.loadHistory` adopts any
  /// image file it finds in the Captures folder — so an unchecked empty file
  /// becomes a permanent phantom capture. The interactive path always guarded
  /// this; full-screen and timer did not.
  static Future<String?> _acceptIfNonEmpty(String path) async {
    final file = File(path);
    if (await file.exists() && await file.length() > 0) return path;
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
    return null;
  }

  /// Generates a new file path for a screenshot
  Future<String> _generateNewPath() async {
    final dir = await getStorageDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return p.join(dir.path, 'snap_$timestamp.png');
  }

  /// Perform interactive area capture across macOS, Windows, and Linux
  Future<String?> captureInteractive() async {
    final targetPath = await _generateNewPath();
    try {
      if (Platform.isMacOS) {
        try {
          final result = await _channel.invokeMethod<String?>(
            'captureInteractive',
            {'targetPath': targetPath},
          );
          if (result != null &&
              await File(result).exists() &&
              (await File(result).length()) > 0) {
            return result;
          }
          if (result == null) {
            // User pressed any key to escape or cancelled capture
            return null;
          }
        } on MissingPluginException catch (_) {
          final result = await Process.run('/usr/sbin/screencapture', [
            '-i',
            targetPath,
          ]);
          final file = File(targetPath);
          if (result.exitCode == 0 && await file.exists()) {
            final len = await file.length();
            if (len > 0) {
              return targetPath;
            } else {
              try {
                await file.delete();
              } catch (_) {}
            }
          }
          return null;
        }
      } else if (Platform.isWindows) {
        // `ms-screenclip:` is the modern overlay; `snippingtool /clip` is the
        // Windows 10 spelling and was *removed* in Windows 11, so it is the
        // fallback rather than the first choice.
        //
        // The clipboard is cleared first and then polled, because the capture
        // is not finished when the launcher returns — it is finished when the
        // user lets go of the selection. Sleeping a fixed 600ms and reading
        // once, as this did, meant every interactive capture on Windows read
        // an empty clipboard and reported failure.
        final winPath = targetPath.replaceAll('/', '\\').replaceAll('"', '\\"');
        final script =
            '''
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
[System.Windows.Forms.Clipboard]::Clear()
try { Start-Process "ms-screenclip:" | Out-Null }
catch { Start-Process "snippingtool" -ArgumentList "/clip" | Out-Null }
\$deadline = (Get-Date).AddSeconds(120)
while ((Get-Date) -lt \$deadline) {
  Start-Sleep -Milliseconds 200
  if ([System.Windows.Forms.Clipboard]::ContainsImage()) {
    \$img = [System.Windows.Forms.Clipboard]::GetImage()
    if (\$img -ne \$null) {
      \$img.Save("$winPath", [System.Drawing.Imaging.ImageFormat]::Png)
      break
    }
  }
}
''';
        // `-Sta`: the clipboard APIs require a single-threaded apartment, and
        // a capture that silently threw here would look like a cancelled snip.
        final result = await Process.run('powershell', [
          '-NoProfile',
          '-Sta',
          '-Command',
          script,
        ]);
        if (result.exitCode != 0) return null;
        // Nothing on the clipboard within the window means the user cancelled.
        return await _acceptIfNonEmpty(targetPath);
      } else if (Platform.isLinux) {
        var result = await Process.run('gnome-screenshot', [
          '-a',
          '-f',
          targetPath,
        ]);
        if (result.exitCode != 0) {
          result = await Process.run('maim', ['-s', targetPath]);
        }
        if (result.exitCode != 0) {
          result = await Process.run('scrot', ['-s', targetPath]);
        }
        final file = File(targetPath);
        if (await file.exists() && await file.length() > 0) {
          return targetPath;
        }
        return null;
      }
    } catch (e) {
      debugPrint('SnipSnap capture error: $e');
    }
    return null;
  }

  /// Perform full screen capture across macOS, Windows, and Linux
  Future<String?> captureFullScreen() async {
    final targetPath = await _generateNewPath();
    try {
      if (Platform.isMacOS) {
        try {
          final result = await _channel.invokeMethod<String?>(
            'captureFullScreen',
            {'targetPath': targetPath},
          );
          if (result != null &&
              await File(result).exists() &&
              (await File(result).length()) > 0) {
            return result;
          }
        } on MissingPluginException catch (_) {
          // `-m` restricts the grab to the main display. Without it a
          // multi-monitor Mac writes one file PER display: only the first is
          // returned, and the rest are adopted as phantom captures by the
          // library scan at next launch. `-x` suppresses the shutter sound,
          // which has already played once for the in-app trigger.
          final result = await Process.run('/usr/sbin/screencapture', [
            '-x',
            '-m',
            targetPath,
          ]);
          if (result.exitCode == 0) {
            return await _acceptIfNonEmpty(targetPath);
          }
        }
      } else if (Platform.isWindows) {
        final winPath = targetPath.replaceAll('/', '\\').replaceAll('"', '\\"');
        // VirtualScreen, not PrimaryScreen: the latter silently drops every
        // secondary monitor. SetProcessDPIAware first, because powershell.exe
        // is not per-monitor DPI aware by default — without it Bounds comes
        // back in virtualised coordinates and the grab is stretched or clipped
        // on any mixed-scaling setup.
        final script =
            '''
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();' -Name U -Namespace W
[W.U]::SetProcessDPIAware() | Out-Null
\$b = [System.Windows.Forms.SystemInformation]::VirtualScreen
\$img = New-Object System.Drawing.Bitmap(\$b.Width, \$b.Height)
\$g = [System.Drawing.Graphics]::FromImage(\$img)
\$g.CopyFromScreen(\$b.Location, [System.Drawing.Point]::Empty, \$b.Size)
\$img.Save("$winPath", [System.Drawing.Imaging.ImageFormat]::Png)
''';
        final result = await Process.run('powershell', [
          '-NoProfile',
          '-Command',
          script,
        ]);
        if (result.exitCode == 0) {
          return await _acceptIfNonEmpty(targetPath);
        }
      } else if (Platform.isLinux) {
        var result = await Process.run('gnome-screenshot', ['-f', targetPath]);
        if (result.exitCode != 0) {
          result = await Process.run('maim', [targetPath]);
        }
        if (result.exitCode != 0) {
          result = await Process.run('scrot', [targetPath]);
        }
        {
          final accepted = await _acceptIfNonEmpty(targetPath);
          if (accepted != null) return accepted;
        }
      }
    } catch (e) {
      debugPrint('SnipSnap capture error: $e');
    }
    return null;
  }

  /// Perform delayed capture with countdown across macOS, Windows, and Linux
  Future<String?> captureTimer(int seconds) async {
    // One meaning on every platform: wait, then grab the whole screen. macOS
    // used to run `screencapture -T n -i`, which is an *interactive selection*
    // after a delay — so the same button did two different things depending on
    // the OS, and neither matched the countdown toast ("Prepare your screen!")
    // the user was reading while it ran.
    await Future<void>.delayed(Duration(seconds: seconds));
    return await captureFullScreen();
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
