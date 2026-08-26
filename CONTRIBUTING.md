# Contributing to snipsnap

Thank you for your interest in contributing to **snipsnap**! We welcome bug reports, feature suggestions, documentation improvements, and code contributions.

---

## Development Setup

### Prerequisites

1. **Flutter SDK**: Ensure you have Flutter 3.24+ (or stable 3.x) installed and configured on your system.
2. **Platform Toolchains**:
   - **macOS**: Xcode with Command Line Tools
   - **Windows**: Visual Studio 2022 with the "Desktop development with C++" workload + Inno Setup 6 (for packaging)
   - **Linux**: `ninja-build`, `libgtk-3-dev`, `libkeybinder-3.0-dev`

### Getting Started

```bash
# Clone the repository
git clone https://github.com/genexis-dev/snipsnap.git
cd snipsnap

# Install Flutter dependencies
flutter pub get

# Generate Drift database code (if modifying models or database)
dart run build_runner build --delete-conflicting-outputs

# Run the app locally on your desktop platform
flutter run
```

---

## Code Quality Standards

We maintain strict quality gates for all code merged into `main`:

1. **Static Analysis**: All Dart code must pass `flutter analyze` with **zero warnings or errors**.
2. **Automated Tests**: Run the full test suite before committing:
   ```bash
   flutter test
   ```
3. **Model-Painter Decoupling**: Keep drawing math and data structures decoupled from rendering logic. Custom painters should only render models without mutating state.
4. **Memory Management**: Explicitly dispose native `ui.Image` references and avoid storing raw bitmaps in history/undo stacks.

---

## Pull Request Guidelines

1. **Branch Naming**: Use descriptive branch names like `feature/arrow-styling` or `fix/blur-overflow`.
2. **Discrete Commits**: Keep commit messages concise, clear, and conventional (e.g. `feat: add rounded corners to callout tool`, `fix: prevent layout overflow in properties panel`).
3. **Tests Included**: Any new features or bug fixes must include unit or widget tests verifying the behavior.
4. **CI Green**: Verify that all CI checks (Windows, macOS, Linux) pass on your pull request.

---

## Security and Privacy

snipsnap is designed around user privacy: all captures, annotations, and OCR operations must remain 100% on-device. Never introduce telemetry, cloud tracking, or remote network uploads of user screenshots without explicit user configuration.
