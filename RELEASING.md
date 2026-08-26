# Releasing snipsnap

snipsnap ships for **Windows, macOS, and Linux**. Every release is driven by a
`v*` git tag; CI builds, tests, and packages all three platforms and attaches
the artifacts to a GitHub Release.

## App identity

| Field | Value |
|---|---|
| Display name | snipsnap |
| Publisher | genexis.dev |
| Application ID | `dev.genexis.snipsnap` |
| Copyright | Copyright © 2026 genexis.dev. All rights reserved. |

The application ID is set in `macos/Runner/Configs/AppInfo.xcconfig`
(`PRODUCT_BUNDLE_IDENTIFIER`), `windows/runner/main.cpp`
(`SetCurrentProcessExplicitAppUserModelID`), `windows/installer/snipsnap.iss`
(`MyAppUserModelId`), `pubspec.yaml` (`msix_config.identity_name`), and
`linux/CMakeLists.txt` (`APPLICATION_ID`). They must all stay identical.

Two Windows values must **never change once shipped**:

- `AppId` in `windows/installer/snipsnap.iss` — the installer's upgrade
  identity. Changing it makes new releases install alongside the old one.
- The AppUserModelID string (`dev.genexis.snipsnap`) — taskbar pinning and
  notifications key off it.

## Versioning

`pubspec.yaml` `version:` is the **single source of truth** (`1.0.0+1` =
semantic version `+` build number). Everything else reads it at build time
(installer filename, DMG name, .deb version, Windows file version, macOS
`CFBundleShortVersionString`/`CFBundleVersion`).

When bumping the version, also update — these are the only places not derived
automatically:

1. `pubspec.yaml` → `msix_config.msix_version` — four segments, `<version>.0`
   (e.g. `1.2.0` → `1.2.0.0`).
2. `lib/views/dialogs/about_dialog.dart` — the hardcoded
   `'Version 1.0.0 (Build 1)'` string (asserted by `test/about_dialog_test.dart`).

Rules:

- The build number (`+N`) must **increase monotonically forever** for any build
  that gets distributed. Never reuse one — stores reject reused build numbers
  at upload, and it is the only way to tell two builds of the same version
  apart.
- Tag names are `v<version>` and must match pubspec (e.g. `version: 1.2.0+5`
  → tag `v1.2.0`).

## Release flow

```bash
# 1. Bump the version (see checklist above), commit.
# 2. Verify locally:
flutter analyze && flutter test

# 3. Tag and push — this triggers .github/workflows/release.yml:
git tag v1.0.0
git push origin main v1.0.0
```

CI then runs one job per platform (`windows-latest`, `macos-latest`,
`ubuntu-latest`), each doing `analyze` → `test` → package, and a final job
that attaches everything to the GitHub Release:

| Artifact | Built by |
|---|---|
| `snipsnap-<version>-windows-x64-setup.exe` | `windows/installer/build_installer.ps1` (Inno Setup) |
| `snipsnap-<version>.dmg` | `scripts/build_macos_dmg.sh` |
| `snipsnap-<version>-linux-x64.tar.gz` | `scripts/build_linux_packages.sh` |
| `snipsnap_<version>_amd64.deb` | `scripts/build_linux_packages.sh` |

`workflow_dispatch` runs the same builds without publishing a release.

## Local builds

Each platform must be built on its own OS (no cross-compiling).

```bash
# Windows (needs Visual Studio C++ workload + Inno Setup 6)
powershell -ExecutionPolicy Bypass -File windows\installer\build_installer.ps1

# Windows MSIX (optional, store/enterprise deployment)
flutter build windows --release
dart run msix:create

# macOS (needs Xcode; create-dmg optional, falls back to hdiutil)
bash scripts/build_macos_dmg.sh

# Linux (needs: sudo apt-get install ninja-build libgtk-3-dev libkeybinder-3.0-dev)
bash scripts/build_linux_packages.sh
```

After changing the icon source (`assets/icon/app_icon.png`, a processed
1024×1024 full-bleed copy of `assets/images/app_logo.png` with transparent
rounded corners), regenerate platform icons:

```bash
dart run flutter_launcher_icons
```

## Signing status

| Platform | Status | Consequence |
|---|---|---|
| Windows | **Unsigned** | SmartScreen shows "Windows protected your PC"; users must click *More info* → *Run anyway*. Only an EV certificate removes this outright. |
| macOS | **Ad-hoc signed** (no Developer ID) | Gatekeeper blocks the app on first launch: "snipsnap can't be opened because Apple cannot check it for malicious software." Users must right-click → Open, or on macOS 15+ approve it under System Settings → Privacy & Security. Fix: set `DEVELOPMENT_TEAM` in `macos/Runner/Configs/AppInfo.xcconfig`, sign with a Developer ID certificate, then notarize and staple — full commands in [docs/release.md](docs/release.md). |
| Linux | Not applicable | No signing; the .deb is unsigned (no apt repository). |

`docs/release.md` has the deep-dive: Developer ID signing, notarization,
stapling, sandbox implications, and Windows installer internals.

## Pre-release checklist

- [ ] `flutter analyze` clean, `flutter test` green
- [ ] Version bumped in all three places (pubspec `version:`, `msix_version`,
      About dialog string); build number never used before
- [ ] Tag matches pubspec version
- [ ] Icons render correctly (Finder, Windows taskbar, Linux launcher)
- [ ] macOS: launched from the DMG on a clean machine; screen-recording
      prompt appears and capture works
- [ ] Windows: installer run on a machine without Visual Studio; capture and
      OCR verified
- [ ] Linux: .deb installs, app appears in the launcher with icon
- [ ] Release notes drafted (CI generates notes from commits; edit after)
