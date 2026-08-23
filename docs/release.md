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

Must be built on Windows; there is no cross-compile.

```bash
flutter build windows --release
```

Output is `build\windows\x64\runner\Release\` — `snipsnap.exe`, `flutter_windows.dll`,
plugin DLLs, and `data\`. Ship the whole directory; the exe will not start alone.

Target machines also need the Visual C++ Redistributable (`msvcp140.dll`,
`vcruntime140.dll`, `vcruntime140_1.dll`) — either bundle those DLLs alongside the exe or
have the installer chain the redistributable.

### Sign

```
signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 /f cert.pfx /p PASS snipsnap.exe
```

An OV certificate starts with no SmartScreen reputation, so early users see a warning
until enough installs accumulate; an EV certificate skips that.

### Installer

Not yet configured. Whichever is chosen (Inno Setup, WiX, or MSIX), the shortcut's
`AppUserModelID` must be `dev.genexis.snipsnap` to match what `main.cpp` sets — otherwise
taskbar pinning and notifications bind to the wrong identity.

## Checklist

- [ ] `flutter analyze` clean, `flutter test` green
- [ ] Build number bumped and never previously published
- [ ] macOS: signed with Developer ID, `get-task-allow` absent, notarized, stapled
- [ ] macOS: launched from the DMG on a clean machine, screen-recording prompt appears
- [ ] Windows: signed, installed from the installer, capture and OCR verified
- [ ] Icons render at every size in Finder and the Windows taskbar
