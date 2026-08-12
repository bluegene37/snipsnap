---
name: flutter-desktop-workflow
description: >-
  Runbook for building, testing, code generating, and debugging Snipsnap desktop applications on macOS, Windows, and Linux.
  Use when running flutter commands, generating code with build_runner for Drift, executing tests, or using dart-mcp-server tools.
---

# Flutter Desktop Development & MCP Tooling Workflow

This skill outlines operational procedures for building, running, code-generating, and debugging the Snipsnap Flutter desktop application efficiently.

---

## 1. Quick Reference Commands

### 1.1 Development & Build
```bash
# Run desktop app on macOS in debug mode
flutter run -d macos

# Run desktop app on Windows
flutter run -d windows

# Run desktop app on Linux
flutter run -d linux
```

### 1.2 Code Generation (Drift Database & Serializers)
```bash
# Generate Drift database accessors and models
dart run build_runner build --delete-conflicting-outputs

# Continuous watch mode during active database development
dart run build_runner watch --delete-conflicting-outputs
```

### 1.3 Testing & Analysis
```bash
# Run unit & widget tests
flutter test

# Run static analysis lints
flutter analyze
```

---

## 2. Leveraging `dart-mcp-server` Tools

When developing with the Antigravity agent, make active use of `dart-mcp-server` tools:

| MCP Tool Name | Purpose | When to Use |
| :--- | :--- | :--- |
| `analyze_files` | Runs Dart analyzer over specific files or directories. | After refactoring models, database definitions, or painters. |
| `get_runtime_errors` | Retrieves recent runtime exceptions and stack traces. | When diagnosing crashes or unexpected exceptions during debug runs. |
| `hot_reload` | Triggers Flutter hot reload on running debug application. | After tweaking UI layout, colors, or painter drawing code. |
| `hot_restart` | Triggers full hot restart on running debug application. | After modifying app state structures or dependencies. |
| `pub_dev_search` | Searches pub.dev for Flutter desktop packages. | When searching for native screen capture, hotkey, or image processing plugins. |
| `widget_inspector` | Inspects widget tree hierarchy. | When debugging layout overflow or widget sizing issues on desktop. |

---

## 3. macOS Native Permission Verification

Snipsnap requires specific native permissions on macOS to operate screen capture and global shortcuts.

### Screen Recording Permission Checklist
- Ensure Info.plist in `macos/Runner/Info.plist` contains appropriate privacy descriptions:
  ```xml
  <key>NSScreenCaptureUsageDescription</key>
  <string>Snipsnap needs screen recording permission to take screenshots and capture selected regions.</string>
  ```
- If screen capture returns a blank/black image or desktop wallpaper only, screen recording permission has not been granted by the user in macOS **System Settings > Privacy & Security > Screen & System Audio Recording**.

### Accessibility Permission Checklist (Global Hotkeys)
- Global hotkey detection requires Accessibility permission in macOS **System Settings > Privacy & Security > Accessibility**.

---

## 4. Debugging & Troubleshooting Workflow

1. **Static Error Check**: Run `dart-mcp-server analyze_files` or `flutter analyze`.
2. **Build Runner Check**: If encountering missing `_$AppDatabase` or `_$CaptureItem` symbols, re-run `dart run build_runner build --delete-conflicting-outputs`.
3. **Runtime Diagnostics**: Inspect error logs via `get_runtime_errors` before attempting code fixes.
