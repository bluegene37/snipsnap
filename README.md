<p align="center">
  <img src="assets/images/snipsnap_logo.png" alt="snipsnap logo" width="128" height="128" />
</p>

<h1 align="center">snipsnap</h1>

<p align="center">
  <b>Fast, high-DPI desktop screen capture, rich vector annotations, on-device OCR, and local capture library.</b><br>
  Built with Flutter for macOS, Windows, and Linux. 100% private and offline-first.
</p>

<p align="center">
  <a href="https://github.com/genexis-dev/snipsnap/actions/workflows/ci.yml"><img src="https://img.shields.io/badge/build-passing-brightgreen.svg" alt="CI Status" /></a>
  <a href="https://flutter.dev"><img src="https://img.shields.io/badge/Flutter-3.47+-02569B.svg?logo=flutter" alt="Flutter" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License" /></a>
  <a href="RELEASING.md"><img src="https://img.shields.io/badge/Version-1.0.0-orange.svg" alt="Version" /></a>
  <a href="#platforms"><img src="https://img.shields.io/badge/Platforms-macOS%20|%20Windows%20|%20Linux-lightgrey.svg" alt="Platforms" /></a>
</p>

---

## ⚡ Features

- 📸 **High-DPI Region & Window Capture**: Multi-monitor global shortcut (`Cmd+Shift+X` / `Ctrl+Shift+X`) overlays seamlessly over full-screen apps and multiple displays.
- ✏️ **Rich Vector Annotations**:
  - **Arrows & Double Arrows**: Precision arrows with curved paths and adjustable heads.
  - **Geometric Shapes**: Rectangles, rounded boxes, ellipses, and speech callout bubbles with custom stroke, fill, and opacity.
  - **Highlighter & Freehand Pen**: Smooth variable-width freehand ink and translucent highlight markers.
  - **Step Counter Badges**: Numbered badges that auto-increment as you click to document numbered workflows.
  - **Pixel Ruler**: Interactive on-screen measurement tool with physical pixel readouts.
  - **Privacy Redaction**: Solid blackout, mosaic pixelation, and Gaussian blur to redact sensitive data, credentials, and PII.
- 🔍 **On-Device OCR**: Instant text extraction using native Apple Vision Framework on macOS and `Windows.Media.Ocr` on Windows. Copy extracted text or formatted tables in one click.
- 🗄️ **Local SQLite Capture Library**: All captures and annotations are stored locally via Drift/SQLite. Search captures by date or OCR content. Zero cloud telemetry, zero account requirement.
- 🎨 **Canvas Styling & Export**: Add background padding, drop shadows, window borders, or export to PNG, JPEG, and clipboard.

---

## ⌨️ Default Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `Cmd+Shift+X` / `Ctrl+Shift+X` | Trigger Global Screen Capture Overlay |
| `V` / `Escape` | Selection / Direct Pointer Tool |
| `R` | Rectangle / Box Tool |
| `O` | Oval / Circle Tool |
| `A` | Arrow Tool |
| `T` | Text Callout Tool |
| `S` | Step Counter Badge Tool |
| `H` | Highlighter Tool |
| `P` | Freehand Pen Tool |
| `B` | Blur / Pixelate Redaction Tool |
| `M` | Pixel Ruler Tool |
| `Cmd+C` / `Ctrl+C` | Copy Annotated Canvas to Clipboard |
| `Cmd+Z` / `Ctrl+Z` | Undo Last Annotation Action |
| `Cmd+Shift+Z` / `Ctrl+Y` | Redo Annotation Action |
| `Delete` / `Backspace` | Delete Selected Annotation Item |

---

## 📦 Downloads & Installation

Pre-built binaries are available under [GitHub Releases](https://github.com/genexis-dev/snipsnap/releases).

| Platform | Format | Build Command / Source |
|---|---|---|
| **macOS** (11+) | `.dmg` | `bash scripts/build_macos_dmg.sh` |
| **Windows** (10/11) | `.exe` (Setup) / `.msix` | `powershell windows/installer/build_installer.ps1` |
| **Linux** (x86_64) | `.deb` / `.tar.gz` | `bash scripts/build_linux_packages.sh` |

---

## 🛠️ Local Development

### Prerequisites

- Flutter SDK (3.24+ recommended)
- macOS: Xcode & Command Line Tools
- Windows: Visual Studio 2022 C++ workload & Inno Setup 6
- Linux: `sudo apt-get install ninja-build libgtk-3-dev libkeybinder-3.0-dev`

### Setup & Run

```bash
# 1. Clone the repository
git clone https://github.com/genexis-dev/snipsnap.git
cd snipsnap

# 2. Get dependencies
flutter pub get

# 3. Generate Drift DB & code artifacts
dart run build_runner build --delete-conflicting-outputs

# 4. Run on your desktop platform
flutter run

# 5. Run static analysis & tests
flutter analyze
flutter test
```

---

## 🚀 Releasing & Packaging

Packaging details, versioning rules, and distribution steps are documented in [RELEASING.md](RELEASING.md) and [docs/release.md](docs/release.md).

To publish a new release:
1. Bump the version in `pubspec.yaml`, `msix_config.msix_version`, and `lib/views/dialogs/about_dialog.dart`.
2. Commit and create a git tag: `git tag v1.0.0 && git push origin main v1.0.0`.
3. GitHub Actions builds all binaries and publishes a GitHub Release automatically.

---

## 🛡️ Security & Privacy

snipsnap is designed with strict offline-first principles. Your captures, screenshots, annotations, and OCR queries are processed 100% locally on your machine. Read our full [SECURITY.md](SECURITY.md) policy.

---

## 📄 License

snipsnap is licensed under the [MIT License](LICENSE).  
Copyright © 2026 genexis.dev. All rights reserved.
