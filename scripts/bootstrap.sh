#!/usr/bin/env bash
# Verifies the toolchain and resolves Swift packages. Safe to run repeatedly.
set -euo pipefail
cd "$(dirname "$0")/.."

MIN_XCODE_MAJOR=26

developer_dir=$(xcode-select -p)
version_line=$(xcodebuild -version | head -1)
major=$(echo "$version_line" | awk '{print $2}' | cut -d. -f1)
echo "Developer dir: $developer_dir"
echo "Toolchain:     $version_line ($(xcodebuild -version | tail -1))"
if [[ -z "$major" || "$major" -lt "$MIN_XCODE_MAJOR" ]]; then
    echo "error: Xcode $MIN_XCODE_MAJOR or later is required (App Store upload requirement, B1)." >&2
    exit 1
fi

if ! xcrun --find swift-format >/dev/null 2>&1; then
    echo "error: swift-format not found in the active Xcode toolchain." >&2
    exit 1
fi

if command -v xcbeautify >/dev/null 2>&1; then
    echo "xcbeautify:    $(xcbeautify --version)"
else
    echo "note: xcbeautify not installed; build output will be unformatted (optional: brew install xcbeautify)."
fi

echo "Resolving packages…"
xcodebuild -resolvePackageDependencies -project RequestPad.xcodeproj -scheme RequestPad >/dev/null
xcodebuild -resolvePackageDependencies -workspace .swiftpm/xcode/package.xcworkspace \
    -scheme RequestPadKit-Package >/dev/null
echo "Bootstrap complete."
