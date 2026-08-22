#!/bin/bash
# Compiles the live CapturePlugin.swift together with overlay_tests.swift and
# runs the behaviour checks. Exits non-zero on the first failing check.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The plugin, verbatim, minus its Flutter import (FlutterStubs.swift stands in
# for those symbols and lives in the same module here).
sed 's/^import FlutterMacOS$//' "$root/macos/Runner/CapturePlugin.swift" > "$work/Plugin.swift"
cat "$here/overlay_tests.swift" >> "$work/Plugin.swift"

# macos12.0 matches MACOSX_DEPLOYMENT_TARGET in the Xcode project. It matters:
# CGDisplayCreateImage and CGWindowListCreateImage are marked obsoleted in
# macOS 15.0 and will not compile against a newer deployment target.
swiftc -O -target arm64-apple-macos12.0 -parse-as-library \
  "$here/FlutterStubs.swift" "$work/Plugin.swift" -o "$work/harness"
"$work/harness"
