# Releasing snipsnap — signing deep-dive

> This document covers the signing/notarization deep-dive. The overall
> release process (versioning, tag flow, CI, checklist) is in
> [../RELEASING.md](../RELEASING.md).

App identity is `dev.genexis.snipsnap` on every platform. It is set in three places and
they must stay in sync:

| Platform | File | Setting |
|---|---|---|
| macOS | `macos/Runner/Configs/AppInfo.xcconfig` | `PRODUCT_BUNDLE_IDENTIFIER` |
| Windows | `windows/runner/main.cpp` | `SetCurrentProcessExplicitAppUserModelID` |
| Linux | `linux/CMakeLists.txt` | `APPLICATION_ID` |

Version and build number come from `pubspec.yaml` (`version: 1.0.0+1`). The build number
must increase on every published build; pass `--build-number=$CI_RUN_NUMBER` in CI rather
than hand-editing.

## macOS

### Build

```bash
flutter build macos --release
```

Produces `build/macos/Build/Products/Release/snipsnap.app`, ad-hoc signed with the
hardened runtime enabled (`ENABLE_HARDENED_RUNTIME = YES` on the Runner Release config).

### Sign for Developer ID

The ad-hoc build carries `com.apple.security.get-task-allow`, which Xcode injects for
local development. **Notarization rejects any binary carrying it**, so the app must be
re-signed against `macos/Runner/Release.entitlements`, which does not contain it. Sign
nested frameworks first, then the outer bundle — `--deep` is deprecated and applies the
wrong entitlements to nested code.

```bash
IDENTITY="Developer ID Application: YOUR NAME (TEAMID)"
APP=build/macos/Build/Products/Release/snipsnap.app

for fw in "$APP"/Contents/Frameworks/*.framework; do
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$fw"
done

codesign --force --options runtime --timestamp \
  --entitlements macos/Runner/Release.entitlements \
  --sign "$IDENTITY" "$APP"
```

Verify before going further — `flags` must show `runtime`, and `get-task-allow` must be
gone from the entitlements:

```bash
codesign -dvvv --entitlements :- build/macos/Build/Products/Release/snipsnap.app
```

### Notarize and staple

Store credentials once with an app-specific password:

```bash
xcrun notarytool store-credentials snipsnap-notary --apple-id you@example.com --team-id TEAMID
```

Then per release:

```bash
hdiutil create -volname snipsnap -srcfolder build/macos/Build/Products/Release/snipsnap.app -ov -format UDZO snipsnap.dmg
codesign --force --timestamp --sign "$IDENTITY" snipsnap.dmg
xcrun notarytool submit snipsnap.dmg --keychain-profile snipsnap-notary --wait
xcrun stapler staple snipsnap.dmg
spctl -a -vvv -t install snipsnap.dmg
```

### Before the first release

- Set `DEVELOPMENT_TEAM` in `AppInfo.xcconfig` (or export it in CI).
- The app is **sandboxed** (`com.apple.security.app-sandbox` in both entitlements files).
  That is required for the Mac App Store and optional for Developer ID. Under the sandbox
  `getApplicationDocumentsDirectory()` resolves inside
  `~/Library/Containers/dev.genexis.snipsnap/Data/Documents`, not the user's `~/Documents`
  — which is where captures and `snipsnap_local.sqlite` land. Dropping the sandbox for a
  Developer ID build would move that data; decide before shipping 1.0, because migrating
  users afterwards is work.
- Screen Recording permission is granted per bundle-ID-plus-signature. Changing the signing
  identity later makes macOS re-prompt every existing user.

## Windows

The installer is a single self-contained `.exe`. Building it needs Windows —
there is no cross-compile from macOS.

### If you have a Windows machine

One command, from the repo root:

```powershell
powershell -ExecutionPolicy Bypass -File windows\installer\build_installer.ps1
```

It builds the app, copies in the Visual C++ runtime, compiles the installer, and
writes `dist\snipsnap-<version>-windows-x64-setup.exe`. That file is the whole
deliverable — send it to someone and they run it.

Prerequisites: Flutter with the Windows desktop toolchain (Visual Studio with
"Desktop development with C++"), and Inno Setup 6.3+. If Inno Setup is missing
the script offers to install it via winget.

Pass `-SkipFlutterBuild` to repackage an existing build without recompiling.

### If you don't have a Windows machine

`.github/workflows/release.yml` runs the same script on a GitHub-hosted
Windows runner (alongside the macOS and Linux jobs). Trigger it from the
repo's **Actions** tab → *Release* → *Run workflow*, or push a `v*` tag —
a tag also publishes a GitHub Release with all platform artifacts attached.
On a manual run the installer appears as a downloadable artifact on the run
summary.

### SmartScreen & Signing Behavior

- **Unsigned builds**: Windows SmartScreen shows a blue "Windows protected your PC" screen on first run. Users click **More info** → **Run anyway**.
- **Signed with Standard (OV) certificate**: SmartScreen warning disappears once download reputation is established.
- **Signed with Extended Validation (EV) certificate / Trusted Signing**: SmartScreen warning is suppressed immediately.

### Signing Windows Binaries

SnipSnap includes a PowerShell signing script [`scripts/sign_windows.ps1`](../scripts/sign_windows.ps1) that automatically locates `signtool.exe`, signs targets with Authenticode SHA-256 and RFC 3161 timestamping, and verifies the signature:

```powershell
# Sign default release artifacts (runner executable and installer) with a PFX file
powershell -ExecutionPolicy Bypass -File scripts\sign_windows.ps1 -CertPath "C:\certs\snipsnap.pfx" -CertPassword "secret"

# Sign with a certificate installed in the Windows Certificate Store
powershell -ExecutionPolicy Bypass -File scripts\sign_windows.ps1 -CertThumbprint "YOUR_CERT_THUMBPRINT"

# Generate a self-signed certificate for local testing
powershell -ExecutionPolicy Bypass -File scripts\sign_windows.ps1 -CreateSelfSigned -CertPassword "Password123!"
```

You can also pass `-CertPath` and `-CertPassword` directly to `windows/installer/build_installer.ps1` to build and sign both `snipsnap.exe` and `snipsnap-<version>-windows-x64-setup.exe` in one step:

```powershell
powershell -ExecutionPolicy Bypass -File windows\installer\build_installer.ps1 -CertPath "C:\certs\snipsnap.pfx" -CertPassword "secret"
```

### GitHub Actions Automated Signing

In CI, `.github/workflows/release.yml` automatically signs the runner binary and the Inno Setup installer executable whenever the following repository secrets are set:

- `WINDOWS_CERT_BASE64` (or `WINDOWS_CERTIFICATE_BASE64`): Base64-encoded `.pfx` certificate.
- `WINDOWS_CERT_PASSWORD` (or `WINDOWS_CERTIFICATE_PASSWORD`): Certificate password.

### Installer internals

`windows/installer/snipsnap.iss` is the Inno Setup script. Two values in it must
not drift:

- **`AppId`** — the GUID Windows matches upgrades and the uninstall entry on.
  Changing it makes the next release install alongside the old one rather than
  over it.
- **`AppUserModelID`** — must stay equal to the string
  `windows/runner/main.cpp` passes to `SetCurrentProcessExplicitAppUserModelID`
  (`dev.genexis.snipsnap`), or taskbar pinning and notifications bind to a
  different identity than the running process claims.

The version is read from `pubspec.yaml` by the build script, so it never needs
editing in the `.iss`.

## Checklist

- [ ] `flutter analyze` clean, `flutter test` green
- [ ] Build number bumped and never previously published
- [ ] macOS: signed with Developer ID, `get-task-allow` absent, notarized, stapled
- [ ] macOS: launched from the DMG on a clean machine, screen-recording prompt appears
- [ ] Windows: installer built, run on a machine that has never had Visual Studio
      or a VC++ redistributable on it, capture and OCR verified
- [ ] Icons render at every size in Finder and the Windows taskbar
