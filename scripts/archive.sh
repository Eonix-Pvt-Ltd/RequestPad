#!/usr/bin/env bash
# Archives and exports RequestPad for App Store Connect (iOS/iPadOS and macOS). Does not upload (human-gated, B9).
#
# Usage: scripts/archive.sh [--platform all|ios|macos]
# Requires: an Apple Distribution certificate for team 835LNLUPAJ available to Xcode (automatic signing).
set -euo pipefail
cd "$(dirname "$0")/.."

platform=all
while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform) platform="$2"; shift 2 ;;
        *) echo "error: unknown option $1" >&2; exit 2 ;;
    esac
done
case "$platform" in all|ios|macos) ;; *) echo "error: --platform must be all, ios or macos" >&2; exit 2 ;; esac

format() {
    if command -v xcbeautify >/dev/null 2>&1; then xcbeautify --quiet; else cat; fi
}

scripts/lint.sh

archive_and_export() {
    local name="$1" destination="$2"
    local archive="build/$name.xcarchive" export_dir="build/$name-export"
    rm -rf "$archive" "$export_dir"
    echo "▸ Archive ($name)"
    xcodebuild archive -project RequestPad.xcodeproj -scheme RequestPad -configuration Release \
        -destination "$destination" -archivePath "$archive" 2>&1 | format
    echo "▸ Export ($name)"
    xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist scripts/exportOptions-appstore.plist \
        -exportPath "$export_dir" -allowProvisioningUpdates 2>&1 | format
    echo "Exported $name to $export_dir"
}

if [[ "$platform" == all || "$platform" == ios ]]; then
    archive_and_export ios 'generic/platform=iOS'
fi
if [[ "$platform" == all || "$platform" == macos ]]; then
    archive_and_export macos 'generic/platform=macOS'
fi
