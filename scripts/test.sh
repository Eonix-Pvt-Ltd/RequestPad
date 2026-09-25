#!/usr/bin/env bash
# Runs lint, the Swift package test suites and the app's unit + UI tests on every platform, with coverage.
# Fails when RPCore or RPStore line coverage is below 80 % (B8).
#
# Usage: scripts/test.sh [--platform all|macos|ios] [--sanitizers] [--analyze]
#   --platform     which destinations to run (default: all = macOS, iPhone simulator, iPad simulator)
#   --sanitizers   additionally run the package suite under ASan and, separately, TSan (macOS)
#   --analyze      additionally run `xcodebuild analyze` for iOS and macOS
#   --skip-macos-ui  skip the macOS UI test target (hosts where XCUITest gets no app window; see HUMAN_HANDOFF H7)
# Environment:
#   IOS_SIMULATOR / IPAD_SIMULATOR   simulator names to use (default: first available iPhone / iPad)
#   CI=true                          sign macOS test products ad hoc (no certificates on CI runners)
set -euo pipefail
cd "$(dirname "$0")/.."

COVERAGE_MINIMUM=80
GATED_MODULES=(RPCore RPStore)
PROJECT=RequestPad.xcodeproj
APP_SCHEME=RequestPad
PACKAGE_WORKSPACE=.swiftpm/xcode/package.xcworkspace
PACKAGE_SCHEME=RequestPadKit-Package
RESULTS=build/test-results
# A private DerivedData folder, so command-line runs never wait on (or disturb) an open Xcode's build lock.
DERIVED_DATA=build/DerivedData

platform=all
run_sanitizers=false
run_analyze=false
skip_macos_ui=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform) platform="$2"; shift 2 ;;
        --skip-macos-ui) skip_macos_ui=true; shift ;;
        --sanitizers) run_sanitizers=true; shift ;;
        --analyze) run_analyze=true; shift ;;
        *) echo "error: unknown option $1" >&2; exit 2 ;;
    esac
done
case "$platform" in all|macos|ios) ;; *) echo "error: --platform must be all, macos or ios" >&2; exit 2 ;; esac

format() {
    if command -v xcbeautify >/dev/null 2>&1; then xcbeautify --quiet; else cat; fi
}

first_simulator() {
    # Prints the name of the first available simulator whose name starts with $1.
    xcrun simctl list devices available -j | python3 -c '
import json, sys
prefix = sys.argv[1]
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        if device["name"].startswith(prefix):
            print(device["name"]); sys.exit(0)
sys.exit(1)' "$1"
}

signing_overrides=()
if [[ "${CI:-}" == "true" ]]; then
    signing_overrides=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=)
fi

run_xcodebuild() {
    local label="$1"; shift
    echo "▸ $label"
    xcodebuild "$@" 2>&1 | format
}

rm -rf "$RESULTS"
mkdir -p "$RESULTS"

scripts/lint.sh

destinations=()
if [[ "$platform" == all || "$platform" == macos ]]; then
    destinations+=("macos|platform=macOS")
fi
if [[ "$platform" == all || "$platform" == ios ]]; then
    iphone="${IOS_SIMULATOR:-$(first_simulator iPhone)}"
    ipad="${IPAD_SIMULATOR:-$(first_simulator iPad)}"
    destinations+=("iphone|platform=iOS Simulator,name=$iphone" "ipad|platform=iOS Simulator,name=$ipad")
fi

for entry in "${destinations[@]}"; do
    name="${entry%%|*}"
    destination="${entry#*|}"
    # The iPad run covers the same package code as iPhone, so package tests run once per OS family.
    if [[ "$name" != ipad ]]; then
        run_xcodebuild "Package tests ($name)" test -workspace "$PACKAGE_WORKSPACE" -scheme "$PACKAGE_SCHEME" \
            -destination "$destination" -derivedDataPath "$DERIVED_DATA" -enableCodeCoverage YES -resultBundlePath "$RESULTS/package-$name.xcresult" \
            ${signing_overrides[@]+"${signing_overrides[@]}"}
    fi
    app_filters=()
    if [[ "$name" == macos ]] && $skip_macos_ui; then
        echo "▸ Skipping macOS UI tests (--skip-macos-ui)"
        app_filters=(-skip-testing:RequestPadUITests)
    fi
    run_xcodebuild "App tests ($name)" test -project "$PROJECT" -scheme "$APP_SCHEME" \
        -destination "$destination" -derivedDataPath "$DERIVED_DATA" -enableCodeCoverage YES -resultBundlePath "$RESULTS/app-$name.xcresult" \
        ${app_filters[@]+"${app_filters[@]}"} ${signing_overrides[@]+"${signing_overrides[@]}"}
done

coverage_bundle="$RESULTS/package-macos.xcresult"
[[ -d "$coverage_bundle" ]] || coverage_bundle="$RESULTS/package-iphone.xcresult"
echo "▸ Coverage gate (${GATED_MODULES[*]} ≥ ${COVERAGE_MINIMUM}%) from $(basename "$coverage_bundle")"
xcrun xccov view --report --only-targets "$coverage_bundle"
xcrun xccov view --report --only-targets --json "$coverage_bundle" | python3 -c '
import json, sys
minimum = float(sys.argv[1]); gated = sys.argv[2:]
targets = {t["name"]: t for t in json.load(sys.stdin)}
failed = False
for name in gated:
    target = targets.get(name)
    if target is None or target["executableLines"] == 0:
        print(f"error: no coverage data for {name}", file=sys.stderr); failed = True; continue
    percent = 100.0 * target["coveredLines"] / target["executableLines"]
    verdict = "ok" if percent >= minimum else "BELOW MINIMUM"
    covered, executable = target["coveredLines"], target["executableLines"]
    print(f"  {name}: {percent:.2f}% ({covered}/{executable}) {verdict}")
    failed |= percent < minimum
sys.exit(1 if failed else 0)' "$COVERAGE_MINIMUM" "${GATED_MODULES[@]}"

if $run_sanitizers; then
    for sanitizer in Address Thread; do
        slug=$(echo "$sanitizer" | tr '[:upper:]' '[:lower:]')
        run_xcodebuild "Package tests under ${sanitizer} Sanitizer (macOS)" test -workspace "$PACKAGE_WORKSPACE" \
            -scheme "$PACKAGE_SCHEME" -destination 'platform=macOS' "-enable${sanitizer}Sanitizer" YES \
            -derivedDataPath "$DERIVED_DATA" \
            -resultBundlePath "$RESULTS/package-${slug}-sanitizer.xcresult" \
            ${signing_overrides[@]+"${signing_overrides[@]}"}
    done
fi

if $run_analyze; then
    run_xcodebuild "Static analysis (macOS)" analyze -project "$PROJECT" -scheme "$APP_SCHEME" \
        -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA" ${signing_overrides[@]+"${signing_overrides[@]}"}
    run_xcodebuild "Static analysis (iOS)" analyze -project "$PROJECT" -scheme "$APP_SCHEME" \
        -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED_DATA"
fi

echo "▸ Result summary"
for bundle in "$RESULTS"/*.xcresult; do
    xcrun xcresulttool get test-results summary --path "$bundle" | python3 -c '
import json, sys
s = json.load(sys.stdin)
result, passed, failed, skipped = s["result"], s["passedTests"], s["failedTests"], s["skippedTests"]
print(f"  {sys.argv[1]}: {result} — passed {passed}, failed {failed}, skipped {skipped}")' "$(basename "$bundle")"
done

echo "All tests passed."
