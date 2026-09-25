#!/usr/bin/env bash
# Developer convenience: `swift build` / `swift test` for the package with compact diagnostics.
# Usage: scripts/dev-build.sh [build|test] [extra swift args…]
set -euo pipefail
cd "$(dirname "$0")/.."
command="${1:-build}"
shift || true
status=0
swift "$command" "$@" >build/dev-build.log 2>&1 || status=$?
{ grep -E "error:|warning:|✘|Test run with|failed after" build/dev-build.log || true; } \
    | { grep -vE "^error: Build failed" || true; } | sed -E 's#.*/RequestPad/(Sources|Tests)/#\1/#' \
    | cut -c1-400 | awk '!seen[$0]++' | head -80
tail -1 build/dev-build.log
exit $status
