# Releasing SnipSnap

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

Produces `build/macos/Build/Products/Release/SnipSnap.app`, ad-hoc signed with the
hardened runtime enabled (`ENABLE_HARDENED_RUNTIME = YES` on the Runner Release config).

### Sign for Developer ID

The ad-hoc build carries `com.apple.security.get-task-allow`, which Xcode injects for
local development. **Notarization rejects any binary carrying it**, so the app must be
re-signed against `macos/Runner/Release.entitlements`, which does not contain it. Sign
nested frameworks first, then the outer bundle — `--deep` is deprecated and applies the
wrong entitlements to nested code.

```bash
IDENTITY="Developer ID Application: YOUR NAME (TEAMID)"
APP=build/macos/Build/Products/Release/SnipSnap.app

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
codesign -dvvv --entitlements :- build/macos/Build/Products/Release/SnipSnap.app
```

### Notarize and staple

Store credentials once with an app-specific password:

```bash
xcrun notarytool store-credentials snipsnap-notary --apple-id you@example.com --team-id TEAMID
```

Then per release:

```bash
hdiutil create -volname SnipSnap -srcfolder build/macos/Build/Products/Release/SnipSnap.app -ov -format UDZO SnipSnap.dmg
codesign --force --timestamp --sign "$IDENTITY" SnipSnap.dmg
xcrun notarytool submit SnipSnap.dmg --keychain-profile snipsnap-notary --wait
xcrun stapler staple SnipSnap.dmg
spctl -a -vvv -t install SnipSnap.dmg
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
writes `dist\SnipSnap-<version>-windows-x64-setup.exe`. That file is the whole
deliverable — send it to someone and they run it.

Prerequisites: Flutter with the Windows desktop toolchain (Visual Studio with
"Desktop development with C++"), and Inno Setup 6.3+. If Inno Setup is missing
the script offers to install it via winget.

Pass `-SkipFlutterBuild` to repackage an existing build without recompiling.

### If you don't have a Windows machine

`.github/workflows/windows-installer.yml` runs the same script on a GitHub-hosted
Windows runner. Trigger it from the repo's **Actions** tab → *Windows installer* →
*Run workflow*, or push a `v*` tag. The installer appears as a downloadable
artifact on the run summary.

### What your friends will see

The installer is **unsigned**, so Windows SmartScreen shows a blue
"Windows protected your PC" screen on first run. They must click **More info**,
then **Run anyway**. There is no way around this without a code-signing
certificate — and an OV certificate still shows the warning until the download
accumulates reputation, so only an EV certificate removes it outright.

Once past that, the install itself is quiet: it is a **per-user** install to
`%LOCALAPPDATA%\Programs\SnipSnap`, so there is no UAC/admin prompt. It adds a
Start-menu entry, optionally a desktop icon, and a normal
Add-or-Remove-Programs uninstall entry.

### Signing it, if you ever get a certificate

```
signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 /f cert.pfx /p PASS dist\SnipSnap-1.0.0-windows-x64-setup.exe
```

Sign `build\windows\x64\runner\Release\snipsnap.exe` before running the
packaging script as well, so the installed binary is signed and not just the
installer.

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
