#!/usr/bin/env bash
set -euo pipefail

# Builds the macOS release app and packages it into a drag-to-/Applications
# DMG at dist/snipsnap-<version>.dmg. The version is read from pubspec.yaml so
# the DMG name never drifts from the app.
#
# The resulting build is ad-hoc signed unless DEVELOPMENT_TEAM is set in
# macos/Runner/Configs/AppInfo.xcconfig; see RELEASING.md for Gatekeeper
# implications and the notarization flow.

# Navigate to project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

APP_NAME="snipsnap"
VERSION="$(sed -n 's/^version:[[:space:]]*\([0-9][0-9.]*\)+\{0,1\}.*/\1/p' pubspec.yaml | head -1)"
if [ -z "$VERSION" ]; then
  echo "Error: could not read version from pubspec.yaml" >&2
  exit 1
fi

ICNS_PATH="macos/Runner/AppIcon.icns"
ICON_SRC="assets/icon/app_icon.png"

# Generate the DMG volume icon if missing (the app icon itself comes from the
# asset catalog, regenerated with `dart run flutter_launcher_icons`).
if [ ! -f "$ICNS_PATH" ] && [ -f "$ICON_SRC" ]; then
  echo "==> Generating $ICNS_PATH from $ICON_SRC..."
  TMP_ICONSET="$(mktemp -d)/$APP_NAME.iconset"
  mkdir -p "$TMP_ICONSET"
  sips -z 16 16     "$ICON_SRC" --out "$TMP_ICONSET/icon_16x16.png" >/dev/null
  sips -z 32 32     "$ICON_SRC" --out "$TMP_ICONSET/icon_16x16@2x.png" >/dev/null
  sips -z 32 32     "$ICON_SRC" --out "$TMP_ICONSET/icon_32x32.png" >/dev/null
  sips -z 64 64     "$ICON_SRC" --out "$TMP_ICONSET/icon_32x32@2x.png" >/dev/null
  sips -z 128 128   "$ICON_SRC" --out "$TMP_ICONSET/icon_128x128.png" >/dev/null
  sips -z 256 256   "$ICON_SRC" --out "$TMP_ICONSET/icon_128x128@2x.png" >/dev/null
  sips -z 256 256   "$ICON_SRC" --out "$TMP_ICONSET/icon_256x256.png" >/dev/null
  sips -z 512 512   "$ICON_SRC" --out "$TMP_ICONSET/icon_256x256@2x.png" >/dev/null
  sips -z 512 512   "$ICON_SRC" --out "$TMP_ICONSET/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$ICON_SRC" --out "$TMP_ICONSET/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$TMP_ICONSET" -o "$ICNS_PATH"
  rm -rf "$(dirname "$TMP_ICONSET")"
fi

echo "==> Building Flutter macOS release binary ($APP_NAME $VERSION)..."
flutter build macos --release

APP_PATH="build/macos/Build/Products/Release/$APP_NAME.app"
DIST_DIR="dist"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"

if [ ! -d "$APP_PATH" ]; then
  echo "Error: $APP_PATH not found!"
  exit 1
fi

mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH"

echo "==> Creating DMG installer package with custom icon..."
if command -v create-dmg >/dev/null 2>&1; then
  VOLICON_ARG=()
  if [ -f "$ICNS_PATH" ]; then
    VOLICON_ARG=(--volicon "$ICNS_PATH")
  fi

  create-dmg \
    --volname "$APP_NAME" \
    "${VOLICON_ARG[@]}" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "$APP_NAME.app" 175 190 \
    --hide-extension "$APP_NAME.app" \
    --app-drop-link 425 190 \
    --format UDZO \
    "$DMG_PATH" \
    "$APP_PATH"
else
  echo "create-dmg not found, falling back to hdiutil..."
  TEMP_DMG_DIR="$(mktemp -d)"
  cp -R "$APP_PATH" "$TEMP_DMG_DIR/"
  ln -s /Applications "$TEMP_DMG_DIR/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$TEMP_DMG_DIR" -ov -format UDZO "$DMG_PATH"
  rm -rf "$TEMP_DMG_DIR"
fi

# Set custom file icon on the .dmg file itself
if [ -f "$ICON_SRC" ] && command -v swift >/dev/null 2>&1; then
  swift -e "
import Cocoa
if let icon = NSImage(contentsOfFile: \"$ICON_SRC\") {
  NSWorkspace.shared.setIcon(icon, forFile: \"$DMG_PATH\", options: [])
}
" >/dev/null 2>&1 || true
fi

echo "==> Successfully created $DMG_PATH ($(du -sh "$DMG_PATH" | cut -f1))"
