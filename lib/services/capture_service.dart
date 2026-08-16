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

  /// Perform interactive area capture across macOS, Windows, and Linux
  Future<String?> captureInteractive() async {
    final targetPath = await _generateNewPath();
    try {
      if (Platform.isMacOS) {
        final result = await Process.run('/usr/sbin/screencapture', ['-i', targetPath]);
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
        // User pressed ESC or cancelled region capture: Return null cleanly!
        return null;
      } else if (Platform.isWindows) {
        // Launch Windows Snipping Tool / Snip & Sketch to clipboard
        await Process.run('snippingtool', ['/clip']);
        // Read clipboard image and persist to targetPath
        final winPath = targetPath.replaceAll('/', '\\').replaceAll('"', '\\"');
        final script = '''
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Start-Sleep -Milliseconds 600
if ([System.Windows.Forms.Clipboard]::ContainsImage()) {
  \$img = [System.Windows.Forms.Clipboard]::GetImage()
  if (\$img -ne \$null) {
    \$img.Save("$winPath", [System.Drawing.Imaging.ImageFormat]::Png)
  }
}
''';
        final result = await Process.run('powershell', ['-NoProfile', '-Command', script]);
        if (result.exitCode == 0 && await File(targetPath).exists()) {
          final len = await File(targetPath).length();
          if (len > 0) return targetPath;
        }
        return null;
      } else if (Platform.isLinux) {
        var result = await Process.run('gnome-screenshot', ['-a', '-f', targetPath]);
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
        final result = await Process.run('/usr/sbin/screencapture', [targetPath]);
        if (result.exitCode == 0 && await File(targetPath).exists()) {
          return targetPath;
        }
      } else if (Platform.isWindows) {
        final winPath = targetPath.replaceAll('/', '\\').replaceAll('"', '\\"');
        final script = '''
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
\$b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
\$img = New-Object System.Drawing.Bitmap(\$b.Width, \$b.Height)
\$g = [System.Drawing.Graphics]::FromImage(\$img)
\$g.CopyFromScreen(\$b.Location, [System.Drawing.Point]::Empty, \$b.Size)
\$img.Save("$winPath", [System.Drawing.Imaging.ImageFormat]::Png)
''';
        final result = await Process.run('powershell', ['-NoProfile', '-Command', script]);
        if (result.exitCode == 0 && await File(targetPath).exists()) {
          return targetPath;
        }
      } else if (Platform.isLinux) {
        var result = await Process.run('gnome-screenshot', ['-f', targetPath]);
        if (result.exitCode != 0) {
          result = await Process.run('maim', [targetPath]);
        }
        if (result.exitCode != 0) {
          result = await Process.run('scrot', [targetPath]);
        }
        if (await File(targetPath).exists()) {
          return targetPath;
        }
      }
    } catch (e) {
      debugPrint('SnipSnap capture error: $e');
    }
    return null;
  }

  /// Perform delayed capture with countdown across macOS, Windows, and Linux
  Future<String?> captureTimer(int seconds) async {
    final targetPath = await _generateNewPath();
    try {
      if (Platform.isMacOS) {
        final result = await Process.run('/usr/sbin/screencapture', ['-T', '$seconds', '-i', targetPath]);
        if (result.exitCode == 0 && await File(targetPath).exists()) {
          return targetPath;
        }
      } else {
        await Future.delayed(Duration(seconds: seconds));
        return await captureFullScreen();
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
