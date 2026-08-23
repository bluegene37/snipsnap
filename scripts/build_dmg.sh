#!/usr/bin/env bash
set -euo pipefail

# Navigate to project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

ICNS_PATH="macos/Runner/AppIcon.icns"
LOGO_PATH="assets/images/app_logo.png"

# Generate high-resolution .icns if missing
if [ ! -f "$ICNS_PATH" ] && [ -f "$LOGO_PATH" ]; then
  echo "==> Generating AppIcon.icns from $LOGO_PATH..."
  TMP_ICONSET="$(mktemp -d)/SnipSnap.iconset"
  mkdir -p "$TMP_ICONSET"
  sips -z 16 16     "$LOGO_PATH" --out "$TMP_ICONSET/icon_16x16.png" >/dev/null
  sips -z 32 32     "$LOGO_PATH" --out "$TMP_ICONSET/icon_16x16@2x.png" >/dev/null
  sips -z 32 32     "$LOGO_PATH" --out "$TMP_ICONSET/icon_32x32.png" >/dev/null
  sips -z 64 64     "$LOGO_PATH" --out "$TMP_ICONSET/icon_32x32@2x.png" >/dev/null
  sips -z 128 128   "$LOGO_PATH" --out "$TMP_ICONSET/icon_128x128.png" >/dev/null
  sips -z 256 256   "$LOGO_PATH" --out "$TMP_ICONSET/icon_128x128@2x.png" >/dev/null
  sips -z 256 256   "$LOGO_PATH" --out "$TMP_ICONSET/icon_256x256.png" >/dev/null
  sips -z 512 512   "$LOGO_PATH" --out "$TMP_ICONSET/icon_256x256@2x.png" >/dev/null
  sips -z 512 512   "$LOGO_PATH" --out "$TMP_ICONSET/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$LOGO_PATH" --out "$TMP_ICONSET/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$TMP_ICONSET" -o "$ICNS_PATH"
  rm -rf "$(dirname "$TMP_ICONSET")"
fi

echo "==> Building Flutter macOS release binary..."
flutter build macos --release

APP_PATH="build/macos/Build/Products/Release/SnipSnap.app"
DIST_DIR="dist"
DMG_PATH="$DIST_DIR/SnipSnap.dmg"

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
    --volname "SnipSnap" \
    "${VOLICON_ARG[@]}" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "SnipSnap.app" 175 190 \
    --hide-extension "SnipSnap.app" \
    --app-drop-link 425 190 \
    --format UDZO \
    "$DMG_PATH" \
    "$APP_PATH"
else
  echo "create-dmg not found, falling back to hdiutil..."
  TEMP_DMG_DIR="$(mktemp -d)"
  cp -R "$APP_PATH" "$TEMP_DMG_DIR/"
  ln -s /Applications "$TEMP_DMG_DIR/Applications"
  hdiutil create -volname "SnipSnap" -srcfolder "$TEMP_DMG_DIR" -ov -format UDZO "$DMG_PATH"
  rm -rf "$TEMP_DMG_DIR"
fi

# Set custom file icon on the .dmg file itself
if [ -f "$LOGO_PATH" ] && command -v swift >/dev/null 2>&1; then
  swift -e "
import Cocoa
if let icon = NSImage(contentsOfFile: \"$LOGO_PATH\") {
  NSWorkspace.shared.setIcon(icon, forFile: \"$DMG_PATH\", options: [])
}
" >/dev/null 2>&1 || true
fi

echo "==> Successfully created $DMG_PATH ($(du -sh "$DMG_PATH" | cut -f1))"
