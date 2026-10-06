#!/bin/bash
set -euo pipefail

# Build and launch the real application with a separate identity and empty config.
devdeck_root=$(cd "$(dirname "$0")/.." && pwd)
devdeck_derived=${DEVDECK_DEVELOPMENT_BUILD:-/tmp/devdeck-development-build}
devdeck_data=${DEVDECK_DEVELOPMENT_DATA:-/tmp/devdeck-development-data}
devdeck_app="$devdeck_derived/Build/Products/Debug/DevDeck.app"

if [[ "$devdeck_data" != /* ]]; then
    echo 'DEVDECK_DEVELOPMENT_DATA must be an absolute path.' >&2
    exit 1
fi
DEVELOPER_DIR=/Applications/Xcode.app xcodebuild -quiet \
    -project "$devdeck_root/DevDeck.xcodeproj" -scheme DevDeck \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$devdeck_derived" \
    PRODUCT_BUNDLE_IDENTIFIER=local.devdeck.development CODE_SIGNING_ALLOWED=NO build
/usr/bin/codesign --force --deep --sign - "$devdeck_app"
/usr/bin/open -n "$devdeck_app" --args --dev-data-directory "$devdeck_data" "$@"
echo "Development configuration: $devdeck_data"
