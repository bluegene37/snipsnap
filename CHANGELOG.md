# Changelog

All notable changes to **snipsnap** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.2] - 2026-08-31

### Added
- **Signed Windows Builds**: The release pipeline now code-signs the Windows
  application binary and installer when a signing certificate is configured
  (`scripts/sign_windows.ps1`), including timestamping and post-sign
  verification. Unsigned builds are still produced when no certificate is
  present.

### Changed
- Hardened the editor-canvas test suite against slow CI machines: tests now
  wait for the capture bitmap to actually decode instead of sleeping for a
  fixed interval.

## [1.0.1] - 2026-08-30

### Added
- **In-App Update Checker**: Checks GitHub Releases for a newer version and
  offers the download from inside the app.
- **In-App User Manual**: Searchable manual dialog with keyboard shortcut
  reference.
- **Adjustable Capture Region**: The macOS capture overlay region can be
  resized before confirming, with Capture and Cancel controls.
- **Cut-and-Move**: A cut region becomes a movable object on the canvas.
- **Progress Overlay**: Long image operations show a progress indicator.

### Fixed
- In-app manual shortcuts now match the real key bindings.
- The manual's sidebar highlight stays on the topic being shown.
- The canvas checkerboard tracks viewport resizes.

### Changed
- Display name standardized as **SnipSnap** across the app, packaging, and
  documentation.

## [1.0.0] - 2026-08-26

### Added
- **High-DPI Region Screen Capture**: Multi-monitor global shortcut screen capture (`Ctrl+Shift+X` / `Cmd+Shift+X`) supporting full-screen and transparent overlay region selection.
- **Rich Vector Annotation Toolset**:
  - Selection / Direct manipulation pointer
  - Precision arrows with single and double arrowheads
  - Geometric shapes (rectangles, rounded boxes, circles/ovals) with configurable stroke, fill, and opacity
  - Highlighters and freehand drawing pens
  - Text callouts and multi-style speech bubbles
  - Step counter badges with auto-incrementing numbers
  - Pixel ruler tool for accurate on-screen UI dimension measurements
  - Pixelate / Gaussian Blur redaction and solid blackouts
- **On-Device Optical Character Recognition (OCR)**:
  - macOS: Native Apple Vision Framework integration
  - Windows: Native `Windows.Media.Ocr` engine
  - Immediate copy to clipboard and region OCR extraction
- **Captures Library & Storage**:
  - Embedded Drift / SQLite database for fast local capture history
  - Searchable library by timestamp, tags, and OCR content
  - 100% private, local on-device processing without cloud dependence
- **Packaging & Distribution**:
  - Windows installer (`.exe`) via Inno Setup and MSIX configuration
  - macOS packaged Disk Image (`.dmg`)
  - Linux standalone `.tar.gz` and `.deb` packages
- **Multi-platform CI/CD**:
  - GitHub Actions automated testing, linting, and automated multi-platform release builds.
