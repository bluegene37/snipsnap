import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// Gene - Nov, 13, 2026: Added AudioInputDevice, OverlayRecordRequest, and NativeVideoPlayerInfo models for Snagit-grade screen recording and native 60fps video playback.
class AudioInputDevice {
  final String id;
  final String name;
  final bool isDefault;

  const AudioInputDevice({
    required this.id,
    required this.name,
    this.isDefault = false,
  });

  factory AudioInputDevice.fromMap(Map<dynamic, dynamic> map) {
    return AudioInputDevice(
      id: (map['id'] as String?) ?? '',
      name: (map['name'] as String?) ?? 'Microphone',
      isDefault: map['isDefault'] == true,
    );
  }
}

class OverlayRecordRequest {
  final double x;
  final double y;
  final double width;
  final double height;
  final int? fps;
  final bool? recordMicrophone;
  final bool? recordSystemAudio;
  final bool? recordCursor;
  final bool? highlightClicks;
  final bool fullScreen;
  final String? microphoneDeviceId;

  const OverlayRecordRequest({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.fps,
    this.recordMicrophone,
    this.recordSystemAudio,
    this.recordCursor,
    this.highlightClicks,
    this.fullScreen = false,
    this.microphoneDeviceId,
  });

  static OverlayRecordRequest? tryParse(String raw) {
    if (!raw.startsWith('record:')) return null;
    final parts = raw.substring('record:'.length).split(':');
    if (parts.length < 4) return null;
    final x = double.tryParse(parts[0]) ?? 0.0;
    final y = double.tryParse(parts[1]) ?? 0.0;
    final w = double.tryParse(parts[2]) ?? 0.0;
    final h = double.tryParse(parts[3]) ?? 0.0;
    int? fps;
    bool? mic;
    bool? sysAudio;
    bool? cursor;
    bool? clicks;
    var fullScreen = w <= 4 || h <= 4;
    String? micId;
    if (parts.length >= 10) {
      fps = int.tryParse(parts[4]);
      mic = parts[5] == '1';
      sysAudio = parts[6] == '1';
      cursor = parts[7] == '1';
      clicks = parts[8] == '1';
      fullScreen = parts[9] == '1' || w <= 4 || h <= 4;
      if (parts.length >= 11 && parts[10].isNotEmpty) {
        micId = Uri.decodeComponent(parts[10]);
      }
    }
    return OverlayRecordRequest(
      x: x,
      y: y,
      width: w,
      height: h,
      fps: fps,
      recordMicrophone: mic,
      recordSystemAudio: sysAudio,
      recordCursor: cursor,
      highlightClicks: clicks,
      fullScreen: fullScreen,
      microphoneDeviceId: micId,
    );
  }
}

class NativeVideoPlayerInfo {
  final int textureId;
  final int durationMs;
  final int width;
  final int height;
  final bool hasAudio;

  const NativeVideoPlayerInfo({
    required this.textureId,
    required this.durationMs,
    required this.width,
    required this.height,
    required this.hasAudio,
  });

  factory NativeVideoPlayerInfo.fromMap(Map<dynamic, dynamic> map) {
    return NativeVideoPlayerInfo(
      textureId: (map['textureId'] as num).toInt(),
      durationMs: (map['durationMs'] as num?)?.toInt() ?? 0,
      width: (map['width'] as num?)?.toInt() ?? 0,
      height: (map['height'] as num?)?.toInt() ?? 0,
      hasAudio: map['hasAudio'] == true,
    );
  }
}

class VideoPlayerListener {
  final void Function(int positionMs, bool isPlaying)? onProgress;
  final VoidCallback? onCompleted;

  const VideoPlayerListener({this.onProgress, this.onCompleted});
}

Future<Uint8List?> _encodePngFramesToGif(Map<String, dynamic> params) async {
  final framePaths = (params['framePaths'] as List<dynamic>).cast<String>();
  final fps = params['fps'] as int;
  final maxWidth = params['maxWidth'] as int;
  if (framePaths.isEmpty) return null;

  final encoder = img.GifEncoder(
    repeat: 0,
    delay: (100 / fps.clamp(1, 30)).round().clamp(3, 100),
  );
  for (final framePath in framePaths) {
    final f = File(framePath);
    if (!await f.exists()) continue;
    final bytes = await f.readAsBytes();
    var decoded = img.decodePng(bytes);
    if (decoded == null) continue;
    if (maxWidth > 0 && decoded.width > maxWidth) {
      decoded = img.copyResize(decoded, width: maxWidth);
    }
    encoder.addFrame(decoded);
  }
  return encoder.finish();
}

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

  /// Whether this launch has already shown the macOS Screen Recording prompt.
  ///
  /// Static on purpose: the grant is per app, not per service instance, and
  /// macOS only applies it after a relaunch anyway, so asking a second time in
  /// the same launch can never succeed — it just puts the dialog back on
  /// screen. Before this flag, every capture re-requested, which for an
  /// ad-hoc signed build after a rebuild (TCC keys the grant to the binary's
  /// cdhash) meant a prompt on every screenshot while System Settings showed
  /// the toggle already on.
  static bool _screenCapturePromptShownThisLaunch = false;

  @visibleForTesting
  static void resetScreenCapturePromptForTesting() {
    _screenCapturePromptShownThisLaunch = false;
  }

  /// Whether the OS will actually let this app see the screen.
  ///
  /// macOS grants Screen Recording per app, and a missing grant does not fail
  /// loudly: the capture succeeds and comes back showing only the desktop
  /// wallpaper. Asking first is the only way to tell the difference between
  /// "the user captured an empty desktop" and "the system refused us".
  ///
  /// When the grant is missing, the system prompt is requested at most once
  /// per launch; later calls return false silently so the caller can explain
  /// instead of the OS nagging.
  ///
  /// True on platforms with no such gate, and true when the plugin is absent,
  /// so the `screencapture` fallback path is never blocked by this check.
  Future<bool> hasScreenCapturePermission() async {
    if (!Platform.isMacOS) return true;
    try {
      final granted =
          await _channel.invokeMethod<bool>('screenCaptureAuthorized') ?? true;
      if (granted) return true;
      if (!_screenCapturePromptShownThisLaunch) {
        _screenCapturePromptShownThisLaunch = true;
        await _channel.invokeMethod<bool>('requestScreenCaptureAccess');
      }
      return false;
    } on MissingPluginException catch (_) {
      return true;
    } catch (e) {
      debugPrint('SnipSnap permission check error: $e');
      return true;
    }
  }

  // Gene - Nov, 03, 2026: Added hasAccessibilityPermission to check whether global hotkeys can receive events on macOS.
  Future<bool> hasAccessibilityPermission() async {
    if (!Platform.isMacOS) return true;
    try {
      final granted =
          await _channel.invokeMethod<bool>('accessibilityAuthorized') ?? true;
      return granted;
    } on MissingPluginException catch (_) {
      return true;
    } catch (e) {
      debugPrint('SnipSnap accessibility check error: $e');
      return true;
    }
  }

  // Gene - Nov, 03, 2026: Added openAccessibilitySettings to deep-link users directly to Privacy & Security > Accessibility.
  Future<void> openAccessibilitySettings() async {
    if (!Platform.isMacOS) return;
    try {
      final opened =
          await _channel.invokeMethod<bool>('openAccessibilitySettings') ??
          false;
      if (!opened) {
        await Process.run('open', [
          'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility',
        ]);
      }
    } catch (e) {
      try {
        await Process.run('open', [
          'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility',
        ]);
      } catch (e2) {
        debugPrint('SnipSnap could not open Accessibility settings: $e2');
      }
    }
  }

  /// Opens System Settings on the Screen Recording pane (macOS only).
  ///
  /// Deep link rather than the generic Privacy pane so the user lands on the
  /// one toggle that matters; a no-op elsewhere.
  Future<void> openScreenRecordingSettings() async {
    if (!Platform.isMacOS) return;
    try {
      await Process.run('open', [
        'x-apple.systempreferences:com.apple.preference.security'
            '?Privacy_ScreenCapture',
      ]);
    } catch (e) {
      debugPrint('SnipSnap could not open Screen Recording settings: $e');
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

  // Gene - Nov, 08, 2026: Added public helper to generate capture/recording file paths with custom prefix & extension.
  Future<String> generateNewMediaPath({
    String prefix = 'snap',
    String extension = 'png',
  }) async {
    final dir = await getStorageDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return p.join(dir.path, '${prefix}_$timestamp.$extension');
  }

  // Gene - Nov, 13, 2026: Isolate video thumbnails (.thumbnails/) and original backups (.originals/) from the main Captures library folder so StorageService never adopts them as separate captures.
  Future<Directory> getThumbnailsDirectory() async {
    final base = await getStorageDirectory();
    final thumbDir = Directory(p.join(base.path, '.thumbnails'));
    if (!await thumbDir.exists()) {
      await thumbDir.create(recursive: true);
    }
    return thumbDir;
  }

  Future<String> generateNewThumbnailPath({String prefix = 'rec_thumb'}) async {
    final dir = await getThumbnailsDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return p.join(dir.path, '${prefix}_$timestamp.png');
  }

  Future<Directory> getOriginalsDirectory() async {
    final base = await getStorageDirectory();
    final origDir = Directory(p.join(base.path, '.originals'));
    if (!await origDir.exists()) {
      await origDir.create(recursive: true);
    }
    return origDir;
  }

  Future<String> getOriginalBackupPath(String captureId) async {
    final dir = await getOriginalsDirectory();
    final safeId = captureId.replaceAll(RegExp(r'[^\w\-]'), '_');
    return p.join(dir.path, '$safeId.mp4');
  }

  /// Perform interactive area capture across macOS, Windows, and Linux
  // Gene - Nov, 13, 2026: Added Snagit pre-recording overlay configuration options (fps, mic, micDeviceId, systemAudio, cursor, clicks).
  // Old implementation:
  // Future<String?> captureInteractive({String initialMode = 'capture'}) async {
  //   final targetPath = await _generateNewPath();
  //   try {
  //     if (Platform.isMacOS) {
  //       try {
  //         final result = await _channel.invokeMethod<String?>(
  //           'captureInteractive',
  //           {
  //             'targetPath': targetPath,
  //             'initialMode': initialMode,
  //           },
  //         );
  Future<String?> captureInteractive({
    String initialMode = 'capture',
    int initialFps = 60,
    bool initialRecordMic = false,
    String? initialMicDeviceId,
    bool initialRecordSystemAudio = true,
    bool initialRecordCursor = true,
    bool initialHighlightClicks = true,
  }) async {
    final targetPath = await _generateNewPath();
    final invokeArgs = <String, dynamic>{
      'targetPath': targetPath,
      'initialMode': initialMode,
      if (initialMode == 'record') ...{
        'initialFps': initialFps,
        'initialRecordMic': initialRecordMic,
        // Gene - Nov, 13, 2026: Use null-aware map element syntax per Dart 3.8 lint rule.
        // Old implementation:
        // if (initialMicDeviceId != null)
        //   'initialMicDeviceId': initialMicDeviceId,
        'initialMicDeviceId': ?initialMicDeviceId,
        'initialRecordSystemAudio': initialRecordSystemAudio,
        'initialRecordCursor': initialRecordCursor,
        'initialHighlightClicks': initialHighlightClicks,
      },
    };
    try {
      if (Platform.isMacOS) {
        try {
          final result = await _channel.invokeMethod<String?>(
            'captureInteractive',
            invokeArgs,
          );
          // Gene - Oct, 27, 2026: If the user clicked Panoramic in the overlay, result is formatted as "scrolling:x:y:w:h".
          // Old implementation:
          // if (result != null &&
          //     await File(result).exists() &&
          //     (await File(result).length()) > 0) {
          //   return result;
          // }
          if (result != null &&
              (result.startsWith('scrolling:') ||
                  result.startsWith('record:'))) {
            return result;
          }
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
        // Gene - Nov, 08, 2026: Use native C++ Win32 captureInteractive overlay first (<15ms GDI/WIC); fall back to PowerShell ms-screenclip only on MissingPluginException.
        // Gene - Nov, 13, 2026: Pass Snagit pre-recording options to native Windows interactive overlay as well.
        // Old implementation:
        //   final result = await _channel.invokeMethod<String?>(
        //     'captureInteractive',
        //     {
        //       'targetPath': targetPath,
        //       'initialMode': initialMode,
        //     },
        //   );
        try {
          final result = await _channel.invokeMethod<String?>(
            'captureInteractive',
            invokeArgs,
          );
          if (result != null &&
              (result.startsWith('scrolling:') ||
                  result.startsWith('record:'))) {
            return result;
          }
          if (result != null &&
              await File(result).exists() &&
              (await File(result).length()) > 0) {
            return result;
          }
          return null;
        } on MissingPluginException catch (_) {}
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
        // Gene - Nov, 08, 2026: Use native C++ Win32 captureFullScreen (<15ms BitBlt + WIC PNG) first; fall back to PowerShell only on MissingPluginException.
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
        } on MissingPluginException catch (_) {}
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

  // Gene - Oct, 27, 2026: Added captureRectBytes for capturing arbitrary screen rectangles for panoramic scrolling capture.
  Future<Uint8List?> captureRectBytes(
    Rect rect, {
    double devicePixelRatio = 1.0,
  }) async {
    final x = rect.left * devicePixelRatio;
    final y = rect.top * devicePixelRatio;
    final w = rect.width * devicePixelRatio;
    final h = rect.height * devicePixelRatio;

    try {
      final bytes = await _channel.invokeMethod<Uint8List>('captureRect', {
        'x': x,
        'y': y,
        'width': w,
        'height': h,
      });
      return bytes;
    } catch (e) {
      debugPrint('SnipSnap captureRect error: $e');
      return null;
    }
  }

  // Gene - Oct, 27, 2026: Added scrolling capture callbacks and native HUD methods for panoramic scrolling capture.
  VoidCallback? _onScrollingDone;
  VoidCallback? _onScrollingCancel;
  // Gene - Nov, 08, 2026: Added native screen recording HUD callbacks and screen recording / video processing channel methods.
  ValueChanged<Map<String, dynamic>>? _onRecordingStopped;
  VoidCallback? _onRecordingCancelled;
  ValueChanged<bool>? _onRecordingStateChanged;
  // Gene - Nov, 13, 2026: Added native restart recording callback, audio mute state sync, and 60fps FlutterTexture video player listener registry.
  VoidCallback? _onRecordingRestartRequested;
  ValueChanged<bool>? _onRecordingMicMutedChanged;
  final Map<int, VideoPlayerListener> _videoPlayerListeners = {};

  void setScrollingCallbacks({VoidCallback? onDone, VoidCallback? onCancel}) {
    _onScrollingDone = onDone;
    _onScrollingCancel = onCancel;
    _channel.setMethodCallHandler(_handleNativeMethodCall);
  }

  // Gene - Nov, 13, 2026: Extended setRecordingCallbacks with onRestartRequested and onMicMutedChanged.
  // Old implementation:
  // void setRecordingCallbacks({
  //   ValueChanged<Map<String, dynamic>>? onStopped,
  //   VoidCallback? onCancelled,
  //   ValueChanged<bool>? onStateChanged,
  // }) {
  //   _onRecordingStopped = onStopped;
  //   _onRecordingCancelled = onCancelled;
  //   _onRecordingStateChanged = onStateChanged;
  //   _channel.setMethodCallHandler(_handleNativeMethodCall);
  // }
  void setRecordingCallbacks({
    ValueChanged<Map<String, dynamic>>? onStopped,
    VoidCallback? onCancelled,
    ValueChanged<bool>? onStateChanged,
    VoidCallback? onRestartRequested,
    ValueChanged<bool>? onMicMutedChanged,
  }) {
    _onRecordingStopped = onStopped;
    _onRecordingCancelled = onCancelled;
    _onRecordingStateChanged = onStateChanged;
    _onRecordingRestartRequested = onRestartRequested;
    _onRecordingMicMutedChanged = onMicMutedChanged;
    _channel.setMethodCallHandler(_handleNativeMethodCall);
  }

  void registerVideoPlayerListener(
    int textureId,
    VideoPlayerListener listener,
  ) {
    _videoPlayerListeners[textureId] = listener;
    _channel.setMethodCallHandler(_handleNativeMethodCall);
  }

  void unregisterVideoPlayerListener(int textureId) {
    _videoPlayerListeners.remove(textureId);
  }

  Future<dynamic> _handleNativeMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onScrollingDone':
        _onScrollingDone?.call();
      case 'onScrollingCancel':
        _onScrollingCancel?.call();
      // Gene - Nov, 13, 2026: Always forward onRecordingStopped even when arguments are null so ScreenRecordingController resets top-bar recording state on failure.
      // Old implementation:
      // case 'onRecordingStopped':
      //   if (call.arguments is Map) {
      //     final map = Map<String, dynamic>.from(call.arguments as Map);
      //     _onRecordingStopped?.call(map);
      //   }
      case 'onRecordingStopped':
        final map = call.arguments is Map
            ? Map<String, dynamic>.from(call.arguments as Map)
            : <String, dynamic>{};
        _onRecordingStopped?.call(map);
      case 'onRecordingCancelled':
        _onRecordingCancelled?.call();
      case 'onRecordingRestartRequested':
        _onRecordingRestartRequested?.call();
      case 'onRecordingMicMutedChanged':
        if (call.arguments is Map) {
          final muted = (call.arguments as Map)['isMuted'] == true;
          _onRecordingMicMutedChanged?.call(muted);
        }
      case 'onRecordingStateChanged':
        if (call.arguments is Map) {
          final isPaused = (call.arguments as Map)['isPaused'] == true;
          _onRecordingStateChanged?.call(isPaused);
        }
      case 'onVideoPlayerProgress':
        if (call.arguments is Map) {
          final args = call.arguments as Map;
          final textureId = (args['textureId'] as num?)?.toInt();
          final positionMs = (args['positionMs'] as num?)?.toInt() ?? 0;
          final isPlaying = args['isPlaying'] == true;
          if (textureId != null) {
            _videoPlayerListeners[textureId]?.onProgress?.call(
              positionMs,
              isPlaying,
            );
          }
        }
      case 'onVideoPlayerCompleted':
        if (call.arguments is Map) {
          final textureId =
              ((call.arguments as Map)['textureId'] as num?)?.toInt();
          if (textureId != null) {
            _videoPlayerListeners[textureId]?.onCompleted?.call();
          }
        }
    }
  }

  // Gene - Nov, 13, 2026: Added main window show/hide, audio input enumeration, microphone permissions, and live mic mute channel helpers.
  Future<void> setMainWindowVisible(bool visible) async {
    if (!Platform.isMacOS && !Platform.isWindows) return;
    try {
      await _channel.invokeMethod<void>('setMainWindowVisible', {
        'visible': visible,
      });
    } catch (e) {
      debugPrint('SnipSnap setMainWindowVisible error: $e');
    }
  }

  Future<List<AudioInputDevice>> listAudioInputDevices() async {
    if (!Platform.isMacOS && !Platform.isWindows) return const [];
    try {
      final res = await _channel.invokeMethod<List<dynamic>>(
        'listAudioInputDevices',
      );
      if (res == null) return const [];
      return res
          .whereType<Map<dynamic, dynamic>>()
          .map(AudioInputDevice.fromMap)
          .where((d) => d.id.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('SnipSnap listAudioInputDevices error: $e');
      return const [];
    }
  }

  Future<bool> hasMicrophonePermission() async {
    if (!Platform.isMacOS) return true;
    try {
      return await _channel.invokeMethod<bool>('microphoneAuthorized') ?? true;
    } on MissingPluginException catch (_) {
      return true;
    } catch (e) {
      debugPrint('SnipSnap microphoneAuthorized error: $e');
      return true;
    }
  }

  Future<bool> requestMicrophonePermission() async {
    if (!Platform.isMacOS) return true;
    try {
      return await _channel.invokeMethod<bool>('requestMicrophoneAccess') ??
          true;
    } on MissingPluginException catch (_) {
      return true;
    } catch (e) {
      debugPrint('SnipSnap requestMicrophoneAccess error: $e');
      return true;
    }
  }

  Future<bool> setRecordingMicrophoneMuted(bool muted) async {
    try {
      return await _channel.invokeMethod<bool>(
            'setRecordingMicrophoneMuted',
            {'muted': muted},
          ) ??
          false;
    } catch (e) {
      debugPrint('SnipSnap setRecordingMicrophoneMuted error: $e');
      return false;
    }
  }

  // Gene - Nov, 13, 2026: Extended startScreenRecording with 60fps default, microphone device ID, system audio, cursor, click highlight, and 3-2-1 countdown.
  // Old implementation:
  // Future<bool> startScreenRecording({
  //   required String targetPath,
  //   required String thumbnailPath,
  //   required bool fullScreen,
  //   Rect? region,
  //   int fps = 30,
  //   bool recordAudio = false,
  // }) async {
  //   try {
  //     final ok = await _channel.invokeMethod<bool>('startScreenRecording', {
  //       'targetPath': targetPath,
  //       'thumbnailPath': thumbnailPath,
  //       'fullScreen': fullScreen,
  //       'x': region?.left ?? 0.0,
  //       'y': region?.top ?? 0.0,
  //       'width': region?.width ?? 0.0,
  //       'height': region?.height ?? 0.0,
  //       'fps': fps,
  //       'recordAudio': recordAudio,
  //     });
  //     return ok ?? false;
  //   } catch (e) {
  //     debugPrint('SnipSnap startScreenRecording error: $e');
  //     return false;
  //   }
  // }
  Future<bool> startScreenRecording({
    required String targetPath,
    required String thumbnailPath,
    required bool fullScreen,
    Rect? region,
    int fps = 60,
    bool recordAudio = false,
    String? microphoneDeviceId,
    bool recordSystemAudio = true,
    bool recordCursor = true,
    bool highlightClicks = true,
    int countdownSeconds = 0,
  }) async {
    try {
      final ok = await _channel.invokeMethod<bool>('startScreenRecording', {
        'targetPath': targetPath,
        'thumbnailPath': thumbnailPath,
        'fullScreen': fullScreen,
        'x': region?.left ?? 0.0,
        'y': region?.top ?? 0.0,
        'width': region?.width ?? 0.0,
        'height': region?.height ?? 0.0,
        'fps': fps,
        'recordAudio': recordAudio,
        // Gene - Nov, 13, 2026: Use null-aware map element syntax per Dart 3.8 lint rule.
        // Old implementation:
        // if (microphoneDeviceId != null)
        //   'microphoneDeviceId': microphoneDeviceId,
        'microphoneDeviceId': ?microphoneDeviceId,
        'recordSystemAudio': recordSystemAudio,
        'recordCursor': recordCursor,
        'highlightClicks': highlightClicks,
        'countdownSeconds': countdownSeconds,
      });
      return ok ?? false;
    } catch (e) {
      debugPrint('SnipSnap startScreenRecording error: $e');
      return false;
    }
  }

  Future<bool> pauseScreenRecording() async {
    try {
      final ok = await _channel.invokeMethod<bool>('pauseScreenRecording');
      return ok ?? false;
    } catch (e) {
      debugPrint('SnipSnap pauseScreenRecording error: $e');
      return false;
    }
  }

  Future<bool> resumeScreenRecording() async {
    try {
      final ok = await _channel.invokeMethod<bool>('resumeScreenRecording');
      return ok ?? false;
    } catch (e) {
      debugPrint('SnipSnap resumeScreenRecording error: $e');
      return false;
    }
  }

  Future<Map<String, dynamic>?> stopScreenRecording() async {
    try {
      final res = await _channel.invokeMethod<dynamic>('stopScreenRecording');
      if (res is Map) {
        return Map<String, dynamic>.from(res);
      }
    } catch (e) {
      debugPrint('SnipSnap stopScreenRecording error: $e');
    }
    return null;
  }

  Future<void> cancelScreenRecording() async {
    try {
      await _channel.invokeMethod<void>('cancelScreenRecording');
    } catch (e) {
      debugPrint('SnipSnap cancelScreenRecording error: $e');
    }
  }

  Future<String?> extractVideoFrame({
    required String videoPath,
    required int timestampMs,
    required String targetPath,
  }) async {
    try {
      final saved = await _channel.invokeMethod<String?>('extractVideoFrame', {
        'videoPath': videoPath,
        'timestampMs': timestampMs,
        'targetPath': targetPath,
      });
      if (saved != null &&
          await File(saved).exists() &&
          await File(saved).length() > 0) {
        return saved;
      }
    } catch (e) {
      debugPrint('SnipSnap extractVideoFrame error: $e');
    }
    return null;
  }

  Future<String?> trimVideo({
    required String videoPath,
    required int startMs,
    required int endMs,
    required String targetPath,
  }) async {
    try {
      final saved = await _channel.invokeMethod<String?>('trimVideo', {
        'videoPath': videoPath,
        'startMs': startMs,
        'endMs': endMs,
        'targetPath': targetPath,
      });
      if (saved != null &&
          await File(saved).exists() &&
          await File(saved).length() > 0) {
        return saved;
      }
    } catch (e) {
      debugPrint('SnipSnap trimVideo error: $e');
    }
    return null;
  }

  // Gene - Nov, 13, 2026: Added Snagit middle-segment cutVideo, animated GIF export (native ImageIO / isolate GifEncoder fallback), and 60fps FlutterTexture video player channel methods.
  Future<({String filePath, int durationMs})?> cutVideo({
    required String videoPath,
    required int cutStartMs,
    required int cutEndMs,
    required String targetPath,
  }) async {
    try {
      final res = await _channel.invokeMethod<dynamic>('cutVideo', {
        'videoPath': videoPath,
        'cutStartMs': cutStartMs,
        'cutEndMs': cutEndMs,
        'targetPath': targetPath,
      });
      if (res is Map) {
        final path = res['filePath'] as String?;
        final durationMs = (res['durationMs'] as num?)?.toInt() ?? 0;
        if (path != null &&
            await File(path).exists() &&
            await File(path).length() > 0) {
          return (filePath: path, durationMs: durationMs);
        }
      } else if (res is String &&
          await File(res).exists() &&
          await File(res).length() > 0) {
        return (filePath: res, durationMs: 0);
      }
    } catch (e) {
      debugPrint('SnipSnap cutVideo error: $e');
    }
    return null;
  }

  Future<String?> exportVideoAsGif({
    required String videoPath,
    required String targetPath,
    required int startMs,
    required int endMs,
    int fps = 15,
    int maxWidth = 720,
  }) async {
    try {
      final saved = await _channel.invokeMethod<String?>('exportVideoAsGif', {
        'videoPath': videoPath,
        'targetPath': targetPath,
        'startMs': startMs,
        'endMs': endMs,
        'fps': fps.clamp(5, 30),
        'maxWidth': maxWidth,
      });
      if (saved != null &&
          await File(saved).exists() &&
          await File(saved).length() > 0) {
        return saved;
      }
    } on MissingPluginException catch (_) {
      return await _exportGifFallback(
        videoPath: videoPath,
        targetPath: targetPath,
        startMs: startMs,
        endMs: endMs,
        fps: fps,
        maxWidth: maxWidth,
      );
    } on PlatformException catch (_) {
      return await _exportGifFallback(
        videoPath: videoPath,
        targetPath: targetPath,
        startMs: startMs,
        endMs: endMs,
        fps: fps,
        maxWidth: maxWidth,
      );
    } catch (e) {
      debugPrint('SnipSnap exportVideoAsGif error: $e');
    }
    return await _exportGifFallback(
      videoPath: videoPath,
      targetPath: targetPath,
      startMs: startMs,
      endMs: endMs,
      fps: fps,
      maxWidth: maxWidth,
    );
  }

  Future<String?> _exportGifFallback({
    required String videoPath,
    required String targetPath,
    required int startMs,
    required int endMs,
    required int fps,
    required int maxWidth,
  }) async {
    final safeFps = fps.clamp(5, 25);
    final rangeMs = (endMs - startMs).clamp(200, 120000);
    final stepMs = (1000 / safeFps).round().clamp(40, 500);
    final tempDir = await Directory.systemTemp.createTemp('snipsnap_gif_');
    final framePaths = <String>[];
    try {
      var idx = 0;
      for (var t = startMs; t <= endMs && idx < 300; t += stepMs) {
        final frameOut = p.join(tempDir.path, 'f_${idx++}.png');
        final extracted = await extractVideoFrame(
          videoPath: videoPath,
          timestampMs: t,
          targetPath: frameOut,
        );
        if (extracted != null) {
          framePaths.add(extracted);
        }
        if (rangeMs < stepMs) break;
      }
      if (framePaths.isEmpty) return null;
      final gifBytes = await compute(_encodePngFramesToGif, {
        'framePaths': framePaths,
        'fps': safeFps,
        'maxWidth': maxWidth,
      });
      if (gifBytes == null || gifBytes.isEmpty) return null;
      await File(targetPath).writeAsBytes(gifBytes, flush: true);
      return await _acceptIfNonEmpty(targetPath);
    } catch (e) {
      debugPrint('SnipSnap GIF fallback error: $e');
      return null;
    } finally {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<NativeVideoPlayerInfo?> createVideoPlayer(String videoPath) async {
    try {
      final res = await _channel.invokeMethod<dynamic>('createVideoPlayer', {
        'videoPath': videoPath,
      });
      if (res is Map && res['textureId'] != null) {
        return NativeVideoPlayerInfo.fromMap(res);
      }
    } on MissingPluginException catch (_) {
      return null;
    } catch (e) {
      debugPrint('SnipSnap createVideoPlayer error: $e');
    }
    return null;
  }

  Future<void> playVideo(int textureId) async {
    try {
      await _channel.invokeMethod<void>('playVideo', {'textureId': textureId});
    } catch (_) {}
  }

  Future<void> pauseVideo(int textureId) async {
    try {
      await _channel.invokeMethod<void>('pauseVideo', {'textureId': textureId});
    } catch (_) {}
  }

  Future<void> seekVideo(int textureId, int positionMs) async {
    try {
      await _channel.invokeMethod<void>('seekVideo', {
        'textureId': textureId,
        'positionMs': positionMs,
      });
    } catch (_) {}
  }

  Future<void> setVideoVolume(int textureId, double volume) async {
    try {
      await _channel.invokeMethod<void>('setVideoVolume', {
        'textureId': textureId,
        'volume': volume.clamp(0.0, 1.0),
      });
    } catch (_) {}
  }

  Future<void> setVideoMuted(int textureId, bool muted) async {
    try {
      await _channel.invokeMethod<void>('setVideoMuted', {
        'textureId': textureId,
        'muted': muted,
      });
    } catch (_) {}
  }

  Future<void> setVideoSpeed(int textureId, double speed) async {
    try {
      await _channel.invokeMethod<void>('setVideoSpeed', {
        'textureId': textureId,
        'speed': speed.clamp(0.25, 4.0),
      });
    } catch (_) {}
  }

  Future<void> disposeVideoPlayer(int textureId) async {
    unregisterVideoPlayerListener(textureId);
    try {
      await _channel.invokeMethod<void>('disposeVideoPlayer', {
        'textureId': textureId,
      });
    } catch (_) {}
  }

  Future<void> showScrollingHud(Rect rect) async {
    if (!Platform.isMacOS) return;
    try {
      await _channel.invokeMethod('showScrollingHud', {
        'x': rect.left,
        'y': rect.top,
        'width': rect.width,
        'height': rect.height,
      });
    } catch (e) {
      debugPrint('SnipSnap showScrollingHud error: $e');
    }
  }

  Future<void> updateScrollingHud(int height, int frameCount) async {
    if (!Platform.isMacOS) return;
    try {
      await _channel.invokeMethod('updateScrollingHud', {
        'height': height,
        'frameCount': frameCount,
      });
    } catch (e) {
      debugPrint('SnipSnap updateScrollingHud error: $e');
    }
  }

  Future<void> closeScrollingHud() async {
    if (!Platform.isMacOS) return;
    try {
      await _channel.invokeMethod('closeScrollingHud');
    } catch (e) {
      debugPrint('SnipSnap closeScrollingHud error: $e');
    }
  }
}
