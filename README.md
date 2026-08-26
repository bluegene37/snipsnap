# snipsnap

snipsnap is a screen capture, annotation, and OCR desktop app for Windows,
macOS, and Linux, built with Flutter. Capture a region of the screen, mark it
up with vector annotation tools, extract text with on-device OCR, and keep a
searchable library of captures backed by Drift/SQLite.

Published by genexis.dev · Application ID `dev.genexis.snipsnap`

## Features

- Region screen capture with a global shortcut (works over full-screen apps)
- Vector annotations: arrows, shapes, text, highlights — editable after the fact
- On-device OCR (Vision on macOS, Windows.Media.Ocr on Windows)
- High-DPI aware capture and export
- Local capture library with SQLite storage; no cloud, no accounts

## Development

```bash
flutter pub get
flutter run          # runs on the host desktop platform
flutter analyze
flutter test
```

## Release builds

Versioning, packaging, signing status, and the tag-push release flow are
documented in [RELEASING.md](RELEASING.md). Quick reference — each platform
builds on its own OS:

```bash
# Windows installer (setup.exe)
powershell -ExecutionPolicy Bypass -File windows\installer\build_installer.ps1

# macOS DMG
bash scripts/build_macos_dmg.sh

# Linux tar.gz + .deb  (needs: ninja-build libgtk-3-dev libkeybinder-3.0-dev)
bash scripts/build_linux_packages.sh
```

Pushing a `v*` tag runs `.github/workflows/release.yml`, which tests and
packages all three platforms and attaches the artifacts to a GitHub Release.

Signing/notarization details live in [docs/release.md](docs/release.md).
