#!/usr/bin/env bash
set -euo pipefail

# Re-signs a built SnipSnap.app with a stable code-signing identity.
#
# Why this exists: `flutter build macos` ad-hoc signs the app, and an ad-hoc
# signature's designated requirement is the binary's cdhash. macOS TCC binds
# the Screen Recording grant to that requirement, so every rebuild or in-app
# update produces a binary the grant no longer matches: System Settings still
# shows SnipSnap toggled on, CGPreflightScreenCaptureAccess says no, and the
# user is prompted on every capture. Signing with a certificate gives a
# requirement keyed to the certificate instead, which survives rebuilds.
#
# Usage:
#   MACOS_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#     scripts/sign_macos_app.sh [path/to/SnipSnap.app]
#
# Any identity from `security find-identity -v -p codesigning` works,
# including an "Apple Development" certificate or a self-signed code-signing
# certificate made in Keychain Access. Only a Developer ID satisfies
# Gatekeeper; the others fix the permission churn without changing how
# Gatekeeper treats the download.
#
# Set MACOS_SIGN_TIMESTAMP=1 for Developer ID builds headed to notarization;
# a secure timestamp needs Apple's timestamp server and a cert it trusts.
#
# With MACOS_SIGN_IDENTITY unset this is a no-op so CI without a certificate
# keeps producing the ad-hoc build.

APP="${1:-build/macos/Build/Products/Release/SnipSnap.app}"
IDENTITY="${MACOS_SIGN_IDENTITY:-}"
ENTITLEMENTS="macos/Runner/Release.entitlements"

if [ -z "$IDENTITY" ]; then
  echo "==> MACOS_SIGN_IDENTITY not set; leaving the ad-hoc signature." >&2
  echo "    Screen Recording grants will not survive rebuilds of this app." >&2
  exit 0
fi

if [ ! -d "$APP" ]; then
  echo "Error: $APP not found" >&2
  exit 1
fi
if [ ! -f "$ENTITLEMENTS" ]; then
  echo "Error: $ENTITLEMENTS not found (run from the project root)" >&2
  exit 1
fi

TIMESTAMP_FLAG="--timestamp=none"
if [ "${MACOS_SIGN_TIMESTAMP:-0}" = "1" ]; then
  TIMESTAMP_FLAG="--timestamp"
fi

echo "==> Signing nested code in $APP with \"$IDENTITY\"..."
# Nested code first, outer bundle last. `--deep` is deprecated and would
# apply the app's entitlements to every framework.
if [ -d "$APP/Contents/Frameworks" ]; then
  find "$APP/Contents/Frameworks" -depth \
    \( -name '*.framework' -o -name '*.dylib' -o -name '*.bundle' \) \
    -print0 |
    while IFS= read -r -d '' nested; do
      codesign --force --options runtime "$TIMESTAMP_FLAG" \
        --sign "$IDENTITY" "$nested"
    done
fi

echo "==> Signing $APP..."
codesign --force --options runtime "$TIMESTAMP_FLAG" \
  --entitlements "$ENTITLEMENTS" \
  --sign "$IDENTITY" "$APP"

echo "==> Verifying..."
codesign --verify --deep --strict "$APP"
codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => /    requirement: /p'
