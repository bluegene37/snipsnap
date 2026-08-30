#!/usr/bin/env bash
set -euo pipefail

# Builds the macOS release app and packages it into an optimized UDZO DMG
# under build/macos/snipsnap-<version>.dmg.

# Navigate to project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

APP_NAME="SnipSnap"
VERSION="$(sed -n 's/^version:[[:space:]]*\([0-9][0-9.]*\)+\{0,1\}.*/\1/p' pubspec.yaml | head -1)"
if [ -z "$VERSION" ]; then
  echo "Error: could not read version from pubspec.yaml" >&2
  exit 1
fi

echo "==> Building Flutter macOS release binary ($APP_NAME $VERSION)..."
flutter build macos --release

APP_PATH="build/macos/Build/Products/Release/$APP_NAME.app"
OUTPUT_DIR="build/macos"
DMG_PATH="$OUTPUT_DIR/$APP_NAME-$VERSION.dmg"

if [ ! -d "$APP_PATH" ]; then
  echo "Error: $APP_PATH not found!" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
rm -f "$DMG_PATH"

echo "==> Creating staging directory for DMG packaging..."
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT

cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

echo "==> Generating optimized UDZO DMG disk image at $DMG_PATH..."
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "==> Successfully created $DMG_PATH ($(du -sh "$DMG_PATH" | cut -f1))"
