# Changelog

All notable changes to **snipsnap** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
