---
name: flutter-platform-integrations
description: >-
  Native platform integration for macOS, Windows, Linux, iOS, and Android.
  Use when managing desktop windows with window_manager, registering global hotkeys, implementing MethodChannels/FFI, or handling platform permissions.
---

# Flutter Native Platform Integrations

This skill outlines strategies for native operating system integration on macOS, Windows, Linux, and mobile platforms.

---

## 1. Platform Channels & FFI

### 1.1 MethodChannel Pattern
```dart
class NativeScreenCaptureService {
  static const MethodChannel _channel = MethodChannel('com.snipsnap.capture');

  static Future<String?> captureInteractiveRegion() async {
    try {
      final result = await _channel.invokeMethod<String>('captureRegion');
      return result;
    } on PlatformException catch (e) {
      debugPrint('Screen capture platform error: ${e.message}');
      return null;
    }
  }
}
```

---

## 2. Desktop Window & Overlay Management (`window_manager`)

### 2.1 Window Setup
```dart
void setupDesktopWindow() async {
  await windowManager.ensureInitialized();

  WindowOptions windowOptions = const WindowOptions(
    size: Size(1280, 800),
    minimumSize: Size(700, 500),
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.normal,
  );

  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}
```

### 2.2 Floating Pin Overlay Windows
Pinned screenshots must run as borderless, always-on-top windows. Always clean up window resources when the pinned window is closed.

---

## 3. Global Hotkeys (`hotkey_manager`)

```dart
// Register global hotkey safely
Future<void> registerHotkey({
  required KeyCode keyCode,
  required List<KeyModifier> modifiers,
  required VoidCallback onTrigger,
}) async {
  final hotKey = HotKey(
    key: keyCode,
    modifiers: modifiers,
    scope: HotKeyScope.system,
  );

  await hotKeyManager.register(
    hotKey,
    keyDownHandler: (hotKey) => onTrigger(),
  );
}
```

---

## 4. Native Permissions & Entitlements

### macOS Entitlements (`macos/Runner/*.entitlements`)
- Screen Recording: System Settings > Privacy & Security > Screen Recording (`NSScreenCaptureUsageDescription` in Info.plist).
- Accessibility: Required for global system hotkeys.
- File Access: `com.apple.security.files.user-selected.read-write` for file pickers.
