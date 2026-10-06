#!/bin/zsh
set -euo pipefail

prototype_root="${0:A:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift build --package-path "$prototype_root"
prototype_bin_dir="$(swift build --package-path "$prototype_root" --show-bin-path)"
prototype_bundle="$prototype_root/.build/DevDeck Prototype.app"
mkdir -p "$prototype_bundle/Contents/MacOS"
cp "$prototype_bin_dir/DevDeckPrototype" "$prototype_bundle/Contents/MacOS/DevDeckPrototype"
cat > "$prototype_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.devdeck.design-prototype</string>
<key>CFBundleName</key><string>DevDeck Prototype</string>
<key>CFBundleExecutable</key><string>DevDeckPrototype</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$prototype_bundle"
open "$prototype_bundle" --args "$@"
