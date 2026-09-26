#!/usr/bin/env bash
# Generates App Store screenshots from the current build (B2, Phase 8) into docs/AppStore/screenshots/:
#   iphone-6.9/  1320×2868   (iPhone Pro Max simulator)
#   ipad-13/     2064×2752   (iPad Pro 13-inch simulator)
#   mac/         2880×1800   (this Mac; needs a Retina display)
# and the in-app purchase review screenshots (App Store Connect → each product → Review Information) into
# docs/AppStore/iap-review/ (iPhone, paywall with each product selected; not shown on the product page).
# Each scene is staged by the app's Debug-only `-ScreenshotScenario` (sample data, real sends to Local Echo, a real
# runner run), so screenshots show the real UI. Simulators get a clean status bar and light appearance; the previous
# appearance is restored afterwards.
#
# Usage: scripts/screenshots.sh [--platform all|ios|macos]
# Environment: IPHONE_SIMULATOR / IPAD_SIMULATOR — simulator names (defaults below).
set -euo pipefail
cd "$(dirname "$0")/.."

platform=all
while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform) platform="$2"; shift 2 ;;
        *) echo "error: unknown option $1" >&2; exit 2 ;;
    esac
done

OUT=docs/AppStore/screenshots
IAP_OUT=docs/AppStore/iap-review
IAP_PRODUCTS=(yearly monthly lifetime)
DERIVED_DATA=build/DerivedData
SCENES=(response chaining graphql runner environments)
# Dedicated simulators (created if missing), so status bar and appearance changes never touch your own devices.
IPHONE="${IPHONE_SIMULATOR:-RequestPad Screenshots iPhone 6.9}"
IPHONE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max"
IPAD="${IPAD_SIMULATOR:-RequestPad Screenshots iPad 13}"
IPAD_TYPE="com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-16GB"

format() {
    if command -v xcbeautify >/dev/null 2>&1; then xcbeautify --quiet; else cat; fi
}

require_size() {
    local file="$1" width="$2" height="$3"
    local actual
    actual=$(sips -g pixelWidth -g pixelHeight "$file" | awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {print w "x" h}')
    if [[ "$actual" != "${width}x${height}" ]]; then
        echo "error: $file is $actual, expected ${width}x${height}" >&2
        exit 1
    fi
}

ensure_simulator() {
    local name="$1" type="$2"
    if ! xcrun simctl list devices available | grep -qF "$name ("; then
        local runtime
        runtime=$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
runtimes = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]]
print(sorted(runtimes, key=lambda r: [int(p) for p in r["version"].split(".")])[-1]["identifier"])')
        echo "▸ Creating simulator \"$name\""
        xcrun simctl create "$name" "$type" "$runtime" >/dev/null
    fi
}

simulator_udid() {
    xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
for runtime, devices in json.load(sys.stdin)["devices"].items():
    for device in devices:
        if device["name"] == name and device["isAvailable"]:
            print(device["udid"]); raise SystemExit
raise SystemExit("error: no available simulator named " + name)' "$1"
}

capture_ios() {
    local label="$1" name="$2" width="$3" height="$4" with_iap="${5:-false}"
    local tests=(-only-testing:RequestPadUITests/ScreenshotTests/testCaptureAppStoreScreenshots)
    if $with_iap; then tests+=(-only-testing:RequestPadUITests/ScreenshotTests/testCaptureInAppPurchaseReviewScreenshots); fi
    local udid appearance was_booted=false results="build/screenshots-$label.xcresult" dir="$OUT/$label"
    udid=$(simulator_udid "$name")
    if xcrun simctl list devices | grep -q "$udid) (Booted)"; then was_booted=true; fi
    xcrun simctl boot "$udid" 2>/dev/null || true
    xcrun simctl bootstatus "$udid" -b >/dev/null
    appearance=$(xcrun simctl ui "$udid" appearance)
    # Leave the simulator as it was found: appearance, status bar, and shut down if this run booted it.
    trap 'xcrun simctl ui "$udid" appearance "$appearance"; xcrun simctl status_bar "$udid" clear
        $was_booted || xcrun simctl shutdown "$udid"' RETURN
    xcrun simctl ui "$udid" appearance light
    xcrun simctl status_bar "$udid" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
        --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
    rm -rf "$results" "$dir" "build/screenshots-$label"
    echo "▸ Screenshots ($label, $name)"
    xcodebuild test -project RequestPad.xcodeproj -scheme RequestPad -destination "id=$udid" \
        -derivedDataPath "$DERIVED_DATA" "${tests[@]}" \
        -resultBundlePath "$results" 2>&1 | format
    xcrun xcresulttool export attachments --path "$results" --output-path "build/screenshots-$label" >/dev/null
    mkdir -p "$dir"
    if $with_iap; then rm -rf "$IAP_OUT"; mkdir -p "$IAP_OUT"; fi
    python3 - "build/screenshots-$label" "$dir" "$IAP_OUT" <<'PY'
import json, os, shutil, sys
source, destination, iap = sys.argv[1], sys.argv[2], sys.argv[3]
for test in json.load(open(os.path.join(source, "manifest.json"))):
    for attachment in test["attachments"]:
        name = attachment.get("suggestedHumanReadableName", "").split("_")[0]
        exported = os.path.join(source, attachment["exportedFileName"])
        if name.startswith("appstore-"):
            shutil.copy(exported, os.path.join(destination, name.removeprefix("appstore-") + ".png"))
        elif name.startswith("iapreview-"):
            shutil.copy(exported, os.path.join(iap, name.removeprefix("iapreview-") + ".png"))
PY
    local count=0
    for file in "$dir"/*.png; do
        require_size "$file" "$width" "$height"
        count=$((count + 1))
    done
    [[ $count -eq ${#SCENES[@]} ]] || { echo "error: $count screenshots in $dir, expected ${#SCENES[@]}" >&2; exit 1; }
    echo "  $count screenshots, ${width}×${height}, in $dir"
    if $with_iap; then
        for product in "${IAP_PRODUCTS[@]}"; do
            [[ -f "$IAP_OUT/$product.png" ]] || { echo "error: missing $IAP_OUT/$product.png" >&2; exit 1; }
            require_size "$IAP_OUT/$product.png" "$width" "$height"
        done
        echo "  ${#IAP_PRODUCTS[@]} in-app purchase review screenshots in $IAP_OUT"
    fi
}

capture_mac() {
    local dir="$OUT/mac" app="$DERIVED_DATA/Build/Products/Debug/RequestPad.app"
    echo "▸ Build (macOS, Debug)"
    xcodebuild build -project RequestPad.xcodeproj -scheme RequestPad -destination 'platform=macOS' \
        -derivedDataPath "$DERIVED_DATA" 2>&1 | format
    rm -rf "$dir"
    mkdir -p "$dir"
    local index=1
    for scene in "${SCENES[@]}"; do
        pkill -f "$app/Contents/MacOS/RequestPad" 2>/dev/null || true
        sleep 1
        open -n "$app" --args -UITestMode -UITestPro -NSQuitAlwaysKeepsWindows NO -ScreenshotScenario "$scene"
        # The scene places the window at (100, 60) with 1440×900 points and finishes staging within this time.
        sleep 12
        local file
        file="$dir/$(printf '%02d' "$index")-$scene.png"
        screencapture -x -R100,60,1440,900 "$file"
        require_size "$file" 2880 1800
        index=$((index + 1))
    done
    pkill -f "$app/Contents/MacOS/RequestPad" 2>/dev/null || true
    echo "  ${#SCENES[@]} screenshots, 2880×1800, in $dir"
}

if [[ "$platform" == all || "$platform" == ios ]]; then
    ensure_simulator "$IPHONE" "$IPHONE_TYPE"
    ensure_simulator "$IPAD" "$IPAD_TYPE"
    capture_ios iphone-6.9 "$IPHONE" 1320 2868 true
    capture_ios ipad-13 "$IPAD" 2064 2752
fi
if [[ "$platform" == all || "$platform" == macos ]]; then
    capture_mac
fi
