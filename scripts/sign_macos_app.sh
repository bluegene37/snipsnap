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
# Gene - Nov, 24, 2026: Support explicit MACOS_SIGN_KEYCHAIN to avoid duplicate-cert ambiguity across keychains and target CI temporary keychains.
KEYCHAIN="${MACOS_SIGN_KEYCHAIN:-}"
ENTITLEMENTS="macos/Runner/Release.entitlements"

# Gene - Nov, 25, 2026: Fail when MACOS_REQUIRE_SIGNED=1 and MACOS_SIGN_IDENTITY is unset so release DMGs never ship with ad-hoc cdhash signatures.
# Old implementation:
# if [ -z "$IDENTITY" ]; then
#   echo "==> MACOS_SIGN_IDENTITY not set; leaving the ad-hoc signature." >&2
#   echo "    Screen Recording grants will not survive rebuilds of this app." >&2
#   exit 0
# fi
if [ -z "$IDENTITY" ]; then
  if [ "${MACOS_REQUIRE_SIGNED:-0}" = "1" ]; then
    echo "Error: MACOS_REQUIRE_SIGNED=1 but MACOS_SIGN_IDENTITY is not set." >&2
    echo "       An ad-hoc signature breaks macOS Screen Recording persistence on every release." >&2
    exit 1
  fi
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

# Gene - Nov, 24, 2026: Enable secure timestamp automatically for Developer ID identities while honoring explicit MACOS_SIGN_TIMESTAMP=0/1 overrides, strip xattrs, sign all nested code directories inside-out, and enforce absence of get-task-allow before notarization.
# Old implementation:
# TIMESTAMP_FLAG="--timestamp=none"
# if [ "${MACOS_SIGN_TIMESTAMP:-0}" = "1" ]; then
#   TIMESTAMP_FLAG="--timestamp"
# fi
#
# echo "==> Signing nested code in $APP with \"$IDENTITY\"..."
# # Nested code first, outer bundle last. `--deep` is deprecated and would
# # apply the app's entitlements to every framework.
# if [ -d "$APP/Contents/Frameworks" ]; then
#   find "$APP/Contents/Frameworks" -depth \
#     \( -name '*.framework' -o -name '*.dylib' -o -name '*.bundle' \) \
#     -print0 |
#     while IFS= read -r -d '' nested; do
#       codesign --force --options runtime "$TIMESTAMP_FLAG" \
#         --sign "$IDENTITY" "$nested"
#     done
# fi
#
# echo "==> Signing $APP..."
# codesign --force --options runtime "$TIMESTAMP_FLAG" \
#   --entitlements "$ENTITLEMENTS" \
#   --sign "$IDENTITY" "$APP"
#
# echo "==> Verifying..."
# codesign --verify --deep --strict "$APP"
# codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => /    requirement: /p'

if [ "${MACOS_SIGN_TIMESTAMP:-}" = "1" ]; then
  TIMESTAMP_FLAG="--timestamp"
elif [ "${MACOS_SIGN_TIMESTAMP:-}" = "0" ]; then
  TIMESTAMP_FLAG="--timestamp=none"
elif [[ "$IDENTITY" == *"Developer ID"* ]]; then
  TIMESTAMP_FLAG="--timestamp"
else
  TIMESTAMP_FLAG="--timestamp=none"
fi

CODESIGN_ARGS=(--force --options runtime "$TIMESTAMP_FLAG")
if [ -n "$KEYCHAIN" ]; then
  CODESIGN_ARGS+=(--keychain "$KEYCHAIN")
fi
CODESIGN_ARGS+=(--sign "$IDENTITY")

echo "==> Stripping extended attributes from $APP..."
xattr -cr "$APP"

echo "==> Signing nested code in $APP with \"$IDENTITY\"..."
# Nested code first, outer bundle last. `--deep` is deprecated and would
# apply the app's entitlements to every framework.
NESTED_DIRS=()
for subdir in Frameworks PlugIns XPCServices Helpers; do
  if [ -d "$APP/Contents/$subdir" ]; then
    NESTED_DIRS+=("$APP/Contents/$subdir")
  fi
done
if [ "${#NESTED_DIRS[@]}" -gt 0 ]; then
  find "${NESTED_DIRS[@]}" -depth \
    \( -name '*.framework' -o -name '*.dylib' -o -name '*.so' -o -name '*.bundle' -o -name '*.xpc' -o -name '*.app' \) \
    -print0 |
    while IFS= read -r -d '' nested; do
      codesign "${CODESIGN_ARGS[@]}" "$nested"
    done
fi

echo "==> Signing $APP..."
codesign "${CODESIGN_ARGS[@]}" --entitlements "$ENTITLEMENTS" "$APP"

echo "==> Verifying..."
codesign --verify --deep --strict --verbose=2 "$APP"
# Gene - Nov, 25, 2026: Verify the signed bundle has a stable non-cdhash designated requirement (and subject.OU for Developer ID) so TCC permissions persist across releases.
# Old implementation:
# codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => /    requirement: /p'
DESIGNATED_REQ="$(codesign -d -r- "$APP" 2>&1)"
printf '%s\n' "$DESIGNATED_REQ" | sed -n 's/^designated => /    requirement: /p'
if printf '%s\n' "$DESIGNATED_REQ" | grep -q "cdhash"; then
  echo "Error: $APP designated requirement is bound to cdhash; Screen Recording grants will break on the next update." >&2
  exit 1
fi
if [[ "$IDENTITY" == *"Developer ID"* ]] && ! printf '%s\n' "$DESIGNATED_REQ" | grep -q "subject.OU"; then
  echo "Error: Developer ID signed $APP is missing subject.OU in its designated requirement." >&2
  exit 1
fi

if [ "$TIMESTAMP_FLAG" = "--timestamp" ]; then
  if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "com.apple.security.get-task-allow"; then
    echo "Error: signed app still contains com.apple.security.get-task-allow (Apple notarization will reject it)." >&2
    exit 1
  fi
fi
