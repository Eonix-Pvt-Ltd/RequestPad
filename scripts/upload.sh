#!/usr/bin/env bash
# Uploads the archives made by scripts/archive.sh to App Store Connect (TestFlight). Human-run only (B9): it asks for
# confirmation before sending anything.
#
# Usage: scripts/upload.sh [--platform all|ios|macos]
# Requires an App Store Connect API key (Users and Access → Integrations → App Store Connect API, role App Manager or
# higher) kept OUTSIDE the repository:
#   ASC_KEY_PATH   path to the AuthKey_XXXXXXXXXX.p8 file
#   ASC_KEY_ID     the key ID
#   ASC_ISSUER_ID  the issuer ID
# Uses `xcodebuild -exportArchive` with destination=upload (never altool). Alternatively upload the files in
# build/*-export with Transporter or Xcode Organizer.
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

for variable in ASC_KEY_PATH ASC_KEY_ID ASC_ISSUER_ID; do
    if [[ -z "${!variable:-}" ]]; then
        echo "error: $variable is not set (see the header of this script)." >&2
        exit 1
    fi
done
if [[ ! -f "$ASC_KEY_PATH" ]]; then
    echo "error: ASC_KEY_PATH does not point to a file." >&2
    exit 1
fi
case "$(cd "$(dirname "$ASC_KEY_PATH")" && pwd)/" in
    "$(pwd)/"*) echo "error: the API key must not be inside the repository." >&2; exit 1 ;;
esac

# The upload options are the App Store export options with destination=upload, generated per run.
options="build/exportOptions-upload.plist"
mkdir -p build
cp scripts/exportOptions-appstore.plist "$options"
plutil -replace destination -string upload "$options"

archives=()
if [[ "$platform" == all || "$platform" == ios ]]; then archives+=(ios); fi
if [[ "$platform" == all || "$platform" == macos ]]; then archives+=(macos); fi

version_of() {
    local archive="build/$1.xcarchive" plist
    plist=$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:ApplicationPath' "$archive/Info.plist")
    plist="$archive/Products/$plist"
    if [[ -f "$plist/Contents/Info.plist" ]]; then plist="$plist/Contents/Info.plist"; else plist="$plist/Info.plist"; fi
    echo "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist"))"
}

echo "About to upload to App Store Connect (team 835LNLUPAJ, lk.eonix.RequestPad):"
for name in "${archives[@]}"; do
    if [[ ! -d "build/$name.xcarchive" ]]; then
        echo "error: build/$name.xcarchive is missing; run scripts/archive.sh first." >&2
        exit 1
    fi
    echo "  $name: version $(version_of "$name")"
done
echo "A build number can be uploaded only once; bump CURRENT_PROJECT_VERSION in Config/Base.xcconfig if it was used."
read -r -p "Upload now? [y/N] " answer
[[ "$answer" == y || "$answer" == Y ]] || { echo "Cancelled; nothing was uploaded."; exit 0; }

for name in "${archives[@]}"; do
    echo "▸ Upload ($name)"
    xcodebuild -exportArchive -archivePath "build/$name.xcarchive" -exportOptionsPlist "$options" \
        -exportPath "build/$name-upload" -allowProvisioningUpdates \
        -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" \
        -authenticationKeyIssuerID "$ASC_ISSUER_ID"
done
echo "Uploaded. Processing in App Store Connect takes 5–30 minutes; watch for the processing email."
