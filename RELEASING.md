# Releasing snipsnap

snipsnap ships for **Windows and macOS** (with Linux support). Every release is driven by a
`v*` git tag; CI builds, tests, and packages release installers and attaches
the artifacts to a GitHub Release.

## App identity

| Field | Value |
|---|---|
| Display name | snipsnap |
| Publisher | genexis.dev |
| Application ID | `dev.genexis.snipsnap` |
| AppId (GUID) | `6b7e88bf-76f5-46aa-b2b9-e152504b86bb` |
| Copyright | Copyright © 2026 genexis.dev. All rights reserved. |

The application ID is set in `macos/Runner/Configs/AppInfo.xcconfig`
(`PRODUCT_BUNDLE_IDENTIFIER`), `windows/runner/main.cpp`
(`SetCurrentProcessExplicitAppUserModelID`), `pubspec.yaml`
(`inno_bundle.id` and `msix_config.identity_name`), and
`linux/CMakeLists.txt` (`APPLICATION_ID`). They must all stay identical.

Two Windows values must **never change once shipped**:

- `id` (AppId GUID) in `pubspec.yaml` (`inno_bundle` configuration) — the installer's upgrade
  identity. Changing it causes new releases to install alongside the old version instead of upgrading.
- The AppUserModelID string (`dev.genexis.snipsnap`) — taskbar pinning and
  notifications key off it.

## Versioning

`pubspec.yaml` `version:` is the **single source of truth** (`1.0.0+1` =
semantic version `+` build number). Everything else reads it at build time
(installer filename, DMG name, Windows file version, macOS
`CFBundleShortVersionString`/`CFBundleVersion`).

When bumping the version, also update:

1. `pubspec.yaml` → `msix_config.msix_version` — four segments, `<version>.0`
   (e.g. `1.2.0` → `1.2.0.0`).
2. `lib/views/dialogs/about_dialog.dart` — the hardcoded
   `'Version 1.0.0 (Build 1)'` string (asserted by `test/about_dialog_test.dart`).

Rules:

- The build number (`+N`) must **increase monotonically forever** for any build
  that gets distributed. Never reuse one — stores reject reused build numbers
  at upload, and it is the only way to distinguish two builds of the same version.
- Tag names are `v<version>` and must match the semantic version in `pubspec.yaml`
  (e.g. `version: 1.0.0+1` → tag `v1.0.0`).

## Release Flow (Step-by-Step)

1. **Bump Version & Update References**
   - Update `version:` in `pubspec.yaml` (e.g. `1.0.0+1`).
   - Update `msix_config.msix_version` in `pubspec.yaml` (e.g. `1.0.0.0`).
   - Update the version string in `lib/views/dialogs/about_dialog.dart`.

2. **Verify Locally**
   ```bash
   dart format --output=none --set-exit-if-changed .
   flutter analyze --fatal-infos
   flutter test
   ```

3. **Commit & Push Changes**
   ```bash
   git add pubspec.yaml lib/views/dialogs/about_dialog.dart
   git commit -m "chore(release): bump version to 1.0.0"
   git push origin main
   ```

4. **Tag & Trigger Automated Release Pipeline**
   ```bash
   git tag v1.0.0
   git push origin v1.0.0
   ```
   Pushing a `v*` tag triggers `.github/workflows/release.yml`, which:
   - Runs tests on `windows-latest` and builds the release installer with `inno_bundle` (`dart run inno_bundle:build --release --no-app`).
   - Runs tests on `macos-latest` and builds the `.dmg` package with `scripts/build_macos_dmg.sh`.
   - Collects all packaged artifacts on `ubuntu-latest` and publishes a new GitHub Release with automated changelog notes.

| Artifact | Built by | Output File |
|---|---|---|
| Windows Installer (`.exe`) | `dart run inno_bundle:build --release --no-app` | `build/windows/x64/installer/Release/snipsnap-1.0.0-windows-installer.exe` |
| macOS Disk Image (`.dmg`) | `scripts/build_macos_dmg.sh` | `build/macos/snipsnap-1.0.0.dmg` |

## Website Download Links

Use the following direct GitHub Releases URL patterns for website download buttons, documentation, and badges:

### Windows Installer
```text
https://github.com/<OWNER>/<REPO>/releases/latest/download/<installer-name>.exe
```
*Example:*
`https://github.com/genexis-dev/snipsnap/releases/latest/download/snipsnap-1.0.0-windows-installer.exe`

### macOS DMG
```text
https://github.com/<OWNER>/<REPO>/releases/latest/download/<app-name>-<version>.dmg
```
*Example:*
`https://github.com/genexis-dev/snipsnap/releases/latest/download/snipsnap-1.0.0.dmg`

## Local Builds

Each platform must be built on its native OS (no cross-compiling).

```bash
# Windows Installer (requires Inno Setup 6)
flutter build windows --release
dart run inno_bundle:build --release --no-app

# Windows MSIX (optional, store/enterprise deployment)
flutter build windows --release
dart run msix:create

# macOS DMG (requires Xcode / hdiutil)
bash scripts/build_macos_dmg.sh
```

After changing the icon source (`assets/icon/app_icon.png`), regenerate platform icons:

```bash
dart run flutter_launcher_icons
```

## Signing Status

| Platform | Status | Consequence |
|---|---|---|
| Windows | **Unsigned** | SmartScreen shows "Windows protected your PC"; users click *More info* → *Run anyway*. An EV certificate removes this warning. |
| macOS | **Ad-hoc signed** (no Developer ID) | Gatekeeper blocks the app on first launch unless right-clicked → Open, or approved under System Settings → Privacy & Security. Set `DEVELOPMENT_TEAM` in `macos/Runner/Configs/AppInfo.xcconfig` to sign, notarize, and staple. |

## Pre-Release Checklist

- [ ] `dart format --output=none --set-exit-if-changed .` clean
- [ ] `flutter analyze --fatal-infos` clean
- [ ] `flutter test` green
- [ ] Version bumped in all places (`pubspec.yaml`, `about_dialog.dart`)
- [ ] Git tag `v<version>` pushed to remote repository
- [ ] GitHub Actions release pipeline completed and artifacts verified
