#!/usr/bin/env bash
# Static checks that must pass on every commit:
#   1. swift-format --strict over all first-party Swift.
#   2. No unreplaced setup placeholders from the product brief (B0/B1). The brief also forbids `{{`, but `{{name}}`
#      is RequestPad's variable syntax, so only the brief's named placeholders are matched (ADR-0020).
#   3. No TODO/FIXME/placeholder markers in shipped sources.
#   4. No APIs that App Review or the brief (B13) forbid: web views, dynamic code loading, arbitrary loads.
#   5. App Store metadata within limits and free of other apps' names (scripts/check-metadata.py).
set -euo pipefail
cd "$(dirname "$0")/.."

status=0

echo "▸ swift-format"
if ! xcrun swift-format lint --strict -r Sources Tests RequestPad RequestPadTests RequestPadUITests Package.swift; then
    status=1
fi

echo "▸ setup placeholders"
placeholder_pattern='YOURTEAM|example\.invalid|\{\{(PRIVACY_URL|TERMS_URL|SUPPORT_URL|SUPPORT_EMAIL)\}\}'
if git grep -nIE "$placeholder_pattern" -- . ':!scripts/lint.sh'; then
    echo "error: unreplaced setup placeholders found (see above)." >&2
    status=1
fi

echo "▸ unfinished-work markers"
marker_pattern='\b(TODO|FIXME|XXX|HACK)\b|fatalError\("not implemented|lorem ipsum'
if git grep -nIiE "$marker_pattern" -- Sources RequestPad Package.swift; then
    echo "error: unfinished-work markers found in shipped sources (see above)." >&2
    status=1
fi

echo "▸ forbidden APIs"
forbidden_pattern='import WebKit|WKWebView|SFSafariViewController|dlopen\(|NSClassFromString|NSAllowsArbitraryLoads|JavaScriptCore'
if git grep -nIE "$forbidden_pattern" -- Sources RequestPad; then
    echo "error: APIs forbidden by App Review guidelines 2.5.2/4.0 or the brief (B13) found (see above)." >&2
    status=1
fi

echo "▸ App Store metadata"
if ! python3 scripts/check-metadata.py; then
    status=1
fi

if [[ $status -eq 0 ]]; then
    echo "Lint passed."
fi
exit $status
