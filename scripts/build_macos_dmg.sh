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

# Gene - Nov, 24, 2026: Allow SKIP_FLUTTER_BUILD=1 for local repackaging/signing checks and add DMG signing, Apple notarization, stapling, and Gatekeeper verification.
# Old implementation:
# echo "==> Building Flutter macOS release binary ($APP_NAME $VERSION)..."
# flutter build macos --release
if [ "${SKIP_FLUTTER_BUILD:-0}" = "1" ]; then
  echo "==> SKIP_FLUTTER_BUILD=1; reusing existing release app bundle..."
else
  echo "==> Building Flutter macOS release binary ($APP_NAME $VERSION)..."
  flutter build macos --release
fi

APP_PATH="build/macos/Build/Products/Release/$APP_NAME.app"
OUTPUT_DIR="build/macos"
DMG_PATH="$OUTPUT_DIR/$APP_NAME-$VERSION.dmg"

if [ ! -d "$APP_PATH" ]; then
  echo "Error: $APP_PATH not found!" >&2
  exit 1
fi

# Stable signature so the Screen Recording grant survives updates. No-op
# unless MACOS_SIGN_IDENTITY is set; see the script header for why.
bash scripts/sign_macos_app.sh "$APP_PATH"

mkdir -p "$OUTPUT_DIR"
rm -f "$DMG_PATH"

# Gene - Nov, 24, 2026: Manage staging and notarization temp artifacts under a single WORK_DIR and resolve Apple notarization credentials.
# Old implementation:
# echo "==> Creating staging directory for DMG packaging..."
# STAGING_DIR="$(mktemp -d)"
# trap 'rm -rf "$STAGING_DIR"' EXIT
#
# cp -R "$APP_PATH" "$STAGING_DIR/"
# ln -s /Applications "$STAGING_DIR/Applications"
#
# echo "==> Generating optimized UDZO DMG disk image at $DMG_PATH..."
# hdiutil create \
#   -volname "$APP_NAME" \
#   -srcfolder "$STAGING_DIR" \
#   -ov \
#   -format UDZO \
#   "$DMG_PATH"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
STAGING_DIR="$WORK_DIR/staging"
NOTARY_DIR="$WORK_DIR/notary"
mkdir -p "$STAGING_DIR" "$NOTARY_DIR"

NOTARY_AUTH=()
if [ -n "${MACOS_NOTARY_PROFILE:-}" ]; then
  NOTARY_AUTH=(--keychain-profile "$MACOS_NOTARY_PROFILE")
  if [ -n "${MACOS_NOTARY_KEYCHAIN:-}" ]; then
    NOTARY_AUTH+=(--keychain "$MACOS_NOTARY_KEYCHAIN")
  fi
elif [ -n "${APPLE_API_KEY_PATH:-}${APPLE_API_KEY_ID:-}${APPLE_API_ISSUER_ID:-}" ]; then
  if [ -z "${APPLE_API_KEY_PATH:-}" ] || [ -z "${APPLE_API_KEY_ID:-}" ] || [ -z "${APPLE_API_ISSUER_ID:-}" ]; then
    echo "Error: Incomplete App Store Connect API notarization credentials; set APPLE_API_KEY_PATH, APPLE_API_KEY_ID, and APPLE_API_ISSUER_ID." >&2
    exit 1
  fi
  if [ ! -f "$APPLE_API_KEY_PATH" ]; then
    echo "Error: APPLE_API_KEY_PATH file not found: $APPLE_API_KEY_PATH" >&2
    exit 1
  fi
  NOTARY_AUTH=(--key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID")
elif [ -n "${APPLE_ID:-}${APPLE_APP_PASSWORD:-}${APPLE_TEAM_ID:-}" ]; then
  if [ -z "${APPLE_ID:-}" ] || [ -z "${APPLE_APP_PASSWORD:-}" ] || [ -z "${APPLE_TEAM_ID:-}" ]; then
    echo "Error: Incomplete Apple ID notarization credentials; set APPLE_ID, APPLE_APP_PASSWORD, and APPLE_TEAM_ID." >&2
    exit 1
  fi
  NOTARY_AUTH=(--apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$APPLE_TEAM_ID")
fi

# Gene - Nov, 25, 2026: Enforce Developer ID signing and Apple notarization credentials before packaging when MACOS_REQUIRE_SIGNED=1.
if [ "${MACOS_REQUIRE_SIGNED:-0}" = "1" ]; then
  if [ -z "${MACOS_SIGN_IDENTITY:-}" ]; then
    echo "Error: MACOS_REQUIRE_SIGNED=1 requires MACOS_SIGN_IDENTITY (Developer ID Application certificate) so macOS Screen Recording grants persist across releases." >&2
    exit 1
  fi
  if [ "${#NOTARY_AUTH[@]}" -eq 0 ]; then
    echo "Error: MACOS_REQUIRE_SIGNED=1 requires Apple notarization credentials (MACOS_NOTARY_PROFILE, APPLE_API_KEY_PATH/APPLE_API_KEY_ID/APPLE_API_ISSUER_ID, or APPLE_ID/APPLE_APP_PASSWORD/APPLE_TEAM_ID)." >&2
    exit 1
  fi
fi

notarize_artifact() {
  local artifact="$1"
  local label="$2"
  local safe_label
  safe_label="$(printf '%s' "$label" | tr -cs 'A-Za-z0-9._-' '_')"
  local result_json="$NOTARY_DIR/${safe_label}_notary.json"

  echo "==> Submitting $label for Apple notarization..."
  set +e
  xcrun notarytool submit "$artifact" "${NOTARY_AUTH[@]}" --wait --output-format json > "$result_json"
  local submit_rc=$?
  set -e

  local status=""
  local submission_id=""
  if [ -s "$result_json" ]; then
    status="$(plutil -extract status raw "$result_json" 2>/dev/null || true)"
    submission_id="$(plutil -extract id raw "$result_json" 2>/dev/null || true)"
  fi

  if [ "$submit_rc" -ne 0 ] || [ "$status" != "Accepted" ]; then
    echo "Error: Apple notarization failed for $label (exit=$submit_rc, status=${status:-unknown})." >&2
    if [ -s "$result_json" ]; then
      cat "$result_json" >&2
    fi
    if [ -n "$submission_id" ]; then
      echo "==> Fetching Apple notarization log for $submission_id..." >&2
      xcrun notarytool log "$submission_id" "${NOTARY_AUTH[@]}" >&2 || true
    fi
    exit 1
  fi

  echo "==> Apple notarization accepted for $label (id: $submission_id)"
}

if [ "${#NOTARY_AUTH[@]}" -gt 0 ]; then
  if [ -z "${MACOS_SIGN_IDENTITY:-}" ]; then
    echo "Error: Notarization credentials are configured, but MACOS_SIGN_IDENTITY is empty." >&2
    exit 1
  fi

  # Notarize and staple the .app before creating the DMG so the installed app
  # in /Applications carries an embedded offline Gatekeeper ticket.
  echo "==> Compressing $APP_NAME.app for Apple notarization..."
  APP_ZIP="$NOTARY_DIR/$APP_NAME.zip"
  ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
  notarize_artifact "$APP_ZIP" "$APP_NAME.app"

  echo "==> Stapling notarization ticket to $APP_PATH..."
  xcrun stapler staple "$APP_PATH"
  xcrun stapler validate "$APP_PATH"
fi

echo "==> Creating staging directory for DMG packaging..."
# Use ditto instead of cp -R to preserve framework symlinks, signatures, and stapled tickets.
ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

echo "==> Generating optimized UDZO DMG disk image at $DMG_PATH..."
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

if [ -n "${MACOS_SIGN_IDENTITY:-}" ]; then
  if [ "${MACOS_SIGN_TIMESTAMP:-}" = "1" ]; then
    DMG_TIMESTAMP_FLAG="--timestamp"
  elif [ "${MACOS_SIGN_TIMESTAMP:-}" = "0" ]; then
    DMG_TIMESTAMP_FLAG="--timestamp=none"
  elif [[ "$MACOS_SIGN_IDENTITY" == *"Developer ID"* ]]; then
    DMG_TIMESTAMP_FLAG="--timestamp"
  else
    DMG_TIMESTAMP_FLAG="--timestamp=none"
  fi

  DMG_CODESIGN_ARGS=(--force "$DMG_TIMESTAMP_FLAG")
  if [ -n "${MACOS_SIGN_KEYCHAIN:-}" ]; then
    DMG_CODESIGN_ARGS+=(--keychain "$MACOS_SIGN_KEYCHAIN")
  fi
  DMG_CODESIGN_ARGS+=(--sign "$MACOS_SIGN_IDENTITY")

  echo "==> Signing $DMG_PATH..."
  codesign "${DMG_CODESIGN_ARGS[@]}" "$DMG_PATH"
  codesign --verify --verbose=2 "$DMG_PATH"

  if [ "${#NOTARY_AUTH[@]}" -gt 0 ]; then
    notarize_artifact "$DMG_PATH" "$(basename "$DMG_PATH")"

    echo "==> Stapling notarization ticket to $DMG_PATH..."
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"

    echo "==> Verifying Gatekeeper acceptance..."
    spctl -a -vvv -t exec "$APP_PATH"
    spctl -a -vvv -t open --context context:primary-signature "$DMG_PATH"
  else
    echo "==> Warning: $DMG_PATH is signed but NOT notarized; Gatekeeper will still reject quarantined downloads until Apple notarization credentials are configured." >&2
  fi
fi

echo "==> Successfully created $DMG_PATH ($(du -sh "$DMG_PATH" | cut -f1))"
