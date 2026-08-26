#!/usr/bin/env bash
set -euo pipefail

# Builds the Linux release bundle and packages it twice:
#   dist/snipsnap-<version>-linux-x64.tar.gz   (portable bundle)
#   dist/snipsnap_<version>_amd64.deb          (installs to /usr/lib/snipsnap,
#                                               with launcher entry and icons)
#
# Version is read from pubspec.yaml. Build deps on Ubuntu:
#   sudo apt-get install ninja-build libgtk-3-dev
# Runtime deps are declared in the .deb control file.
#
# Pass --skip-build to package an existing build/linux/x64/release/bundle.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

APP_NAME="snipsnap"
APP_ID="dev.genexis.snipsnap"
VERSION="$(sed -n 's/^version:[[:space:]]*\([0-9][0-9.]*\)+\{0,1\}.*/\1/p' pubspec.yaml | head -1)"
if [ -z "$VERSION" ]; then
  echo "Error: could not read version from pubspec.yaml" >&2
  exit 1
fi

if [ "${1:-}" != "--skip-build" ]; then
  echo "==> Building Flutter Linux release bundle ($APP_NAME $VERSION)..."
  flutter build linux --release
fi

BUNDLE="build/linux/x64/release/bundle"
if [ ! -d "$BUNDLE" ]; then
  echo "Error: $BUNDLE not found!" >&2
  exit 1
fi

DIST_DIR="dist"
mkdir -p "$DIST_DIR"

# --- tar.gz -------------------------------------------------------------------
TARBALL="$DIST_DIR/$APP_NAME-$VERSION-linux-x64.tar.gz"
echo "==> Creating $TARBALL..."
rm -f "$TARBALL"
tar -czf "$TARBALL" -C "$BUNDLE" .

# --- .deb ---------------------------------------------------------------------
DEB_NAME="${APP_NAME}_${VERSION}_amd64"
DEB_ROOT="$(mktemp -d)/$DEB_NAME"
echo "==> Staging $DEB_NAME.deb..."

install -d "$DEB_ROOT/DEBIAN" \
           "$DEB_ROOT/usr/lib/$APP_NAME" \
           "$DEB_ROOT/usr/bin" \
           "$DEB_ROOT/usr/share/applications"
cp -r "$BUNDLE"/. "$DEB_ROOT/usr/lib/$APP_NAME/"
ln -s "../lib/$APP_NAME/$APP_NAME" "$DEB_ROOT/usr/bin/$APP_NAME"

install -m 644 "linux/packaging/$APP_ID.desktop" "$DEB_ROOT/usr/share/applications/"
for size in 128 256 512; do
  install -d "$DEB_ROOT/usr/share/icons/hicolor/${size}x${size}/apps"
  install -m 644 "linux/packaging/icons/app_icon_$size.png" \
    "$DEB_ROOT/usr/share/icons/hicolor/${size}x${size}/apps/$APP_ID.png"
done

INSTALLED_SIZE="$(du -sk "$DEB_ROOT/usr" | cut -f1)"
cat > "$DEB_ROOT/DEBIAN/control" <<EOF
Package: $APP_NAME
Version: $VERSION
Section: utils
Priority: optional
Architecture: amd64
Installed-Size: $INSTALLED_SIZE
Depends: libgtk-3-0 (>= 3.24), libkeybinder-3.0-0
Recommends: zenity
Maintainer: genexis.dev <bluegene37@gmail.com>
Homepage: https://github.com/bluegene37/snipsnap
Description: Screen capture, annotation, and OCR desktop app
 snipsnap is a screen capture and markup tool. Capture a region of the
 screen, annotate it with vector tools, extract text with OCR, and manage
 a searchable library of captures.
EOF

DEB_PATH="$DIST_DIR/$DEB_NAME.deb"
rm -f "$DEB_PATH"
dpkg-deb --build --root-owner-group "$DEB_ROOT" "$DEB_PATH"
rm -rf "$(dirname "$DEB_ROOT")"

echo "==> Done:"
ls -lh "$TARBALL" "$DEB_PATH"
