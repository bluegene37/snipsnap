#!/usr/bin/env bash
# Gene - Nov, 20, 2026: Builds universal/active-arch Rust staticlib libsnipsnap_core.a for macOS Xcode Runner builds.
set -euo pipefail

export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo not found on PATH ($PATH). Install Rust via https://rustup.rs" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$REPO_ROOT/native/snipsnap_core/Cargo.toml"
CARGO_TARGET_DIR="$REPO_ROOT/build/rust_macos"

OUT_DIR="${BUILT_PRODUCTS_DIR:-$REPO_ROOT/build/rust_macos/out}"
mkdir -p "$OUT_DIR"
OUT_LIB="$OUT_DIR/libsnipsnap_core.a"

REQ_ARCHS="${ARCHS:-$(uname -m)}"
LIBS=()

for arch in $REQ_ARCHS; do
  case "$arch" in
    arm64)
      RUST_TARGET="aarch64-apple-darwin"
      ;;
    x86_64)
      RUST_TARGET="x86_64-apple-darwin"
      ;;
    *)
      echo "error: unsupported macOS arch '$arch'" >&2
      exit 1
      ;;
  esac

  cargo build \
    --manifest-path "$MANIFEST" \
    --release \
    --target "$RUST_TARGET" \
    --target-dir "$CARGO_TARGET_DIR"

  LIBS+=("$CARGO_TARGET_DIR/$RUST_TARGET/release/libsnipsnap_core.a")
done

if [ "${#LIBS[@]}" -eq 1 ]; then
  cp -f "${LIBS[0]}" "$OUT_LIB"
else
  lipo -create "${LIBS[@]}" -output "$OUT_LIB"
fi

echo "==> Built $OUT_LIB ($REQ_ARCHS)"
