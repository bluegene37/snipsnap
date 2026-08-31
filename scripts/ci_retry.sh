#!/usr/bin/env bash
#
# Retries a command, but only when it failed for a known-transient reason.
#
# Dart build hooks download prebuilt native libraries at build time.
# package:sqlite3 fetches them from GitHub release assets and hashes the
# response body *without checking the HTTP status code or content length*
# (see lib/src/hook/compile/description.dart in that package), so a rate
# limited, truncated, or 5xx response from GitHub is reported as:
#
#   Bad state: Hash of downloaded file libsqlite3.arm64.macos.dylib is <x>,
#   expected <y>.
#
# That reads like a corrupt dependency but is really a failed download, and it
# succeeds on a retry. Genuine build failures do not match the pattern and are
# not retried, so a broken build still fails on the first attempt.
#
# Usage: bash scripts/ci_retry.sh <command> [args...]
#
# Env overrides: CI_RETRY_ATTEMPTS (3), CI_RETRY_DELAY (15), CI_RETRY_PATTERN.

set -uo pipefail

attempts="${CI_RETRY_ATTEMPTS:-3}"
delay="${CI_RETRY_DELAY:-15}"
pattern="${CI_RETRY_PATTERN:-Hash of downloaded file|Building native assets failed|Building assets for package:|CouldNotDownloadException}"

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

for attempt in $(seq 1 "$attempts"); do
  "$@" 2>&1 | tee "$log"
  status="${PIPESTATUS[0]}"

  if [ "$status" -eq 0 ]; then
    exit 0
  fi

  if ! grep -Eq "$pattern" "$log"; then
    echo "'$*' failed (exit $status) for a non-transient reason; not retrying." >&2
    exit "$status"
  fi

  if [ "$attempt" -eq "$attempts" ]; then
    echo "::error::'$*' failed after $attempts attempts (exit $status)"
    exit "$status"
  fi

  echo "::warning::'$*' hit a transient native-asset download failure (attempt $attempt/$attempts); retrying in ${delay}s"
  sleep "$delay"
done
