#!/usr/bin/env bash
# Syncs the app's String Catalog with the strings the compiler extracted during the last build (Xcode does this
# automatically when building in the IDE; command-line builds need this step). Run after scripts/test.sh or any
# app build that used -derivedDataPath build/DerivedData.
set -euo pipefail
cd "$(dirname "$0")/.."
catalog="RequestPad/Resources/Localizable.xcstrings"
intermediates="build/DerivedData/Build/Intermediates.noindex/RequestPad.build"
args=()
while IFS= read -r file; do
    args+=(--stringsdata "$file")
done < <(find "$intermediates"/Debug*/RequestPad.build -name "*.stringsdata" ! -name "ExtractedAppShortcutsMetadata.stringsdata" 2>/dev/null)
if [ ${#args[@]} -eq 0 ]; then
    echo "No extracted strings found under $intermediates; build the app first." >&2
    exit 1
fi
xcrun xcstringstool sync "$catalog" "${args[@]}"
echo "Synced $catalog from $((${#args[@]} / 2)) files."
