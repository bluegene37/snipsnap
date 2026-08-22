---
name: flutter-code-quality-devops
description: >-
  Static analysis, code generation, and multi-platform build workflows for Flutter.
  Use when configuring analysis_options.yaml, running build_runner for Drift/Freezed, packaging release binaries, or automating CI pipelines.
---

# Flutter Code Quality & DevOps

This skill covers code generation automation, strict static analysis, and multi-platform build operations.

---

## 1. Code Generation (`build_runner`)

When modifying database tables (`lib/database/`), serializable models, or Freezed classes:

```bash
# Run one-off build runner with conflict resolution
dart run build_runner build --delete-conflicting-outputs

# Watch mode during active schema development
dart run build_runner watch --delete-conflicting-outputs
```

---

## 2. Static Analysis & Lints

Maintain zero analyzer warnings and errors across the codebase.

```bash
# Check Dart & Flutter static analysis
flutter analyze

# Format code according to Dart style guide
dart format .
```

---

## 3. Multi-Platform Build Commands

```bash
# macOS desktop build
flutter build macos --release

# Windows desktop build
flutter build windows --release

# Linux desktop build
flutter build linux --release

# Web application build
flutter build web --release
```
