#!/usr/bin/env bash
#
# Build DevDeck.app in Release mode and package it into a .dmg — without Developer ID signing.
# Dependencies: Xcode CLI tools and hdiutil (bundled with macOS) only. No create-dmg/brew needed.
#
# Output: build/DevDeck-<version>.dmg
# Usage: ./scripts/build-dmg.sh
#
set -euo pipefail

PROJECT="DevDeck.xcodeproj"
SCHEME="DevDeck"
APP_NAME="DevDeck"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUILD_DIR="$ROOT/build"
DD="$BUILD_DIR/DerivedData"
STAGING="$BUILD_DIR/dmg-staging"

# Version from project settings (MARKETING_VERSION), fallback 0.0.0.
VERSION="$(xcodebuild -showBuildSettings -project "$PROJECT" -scheme "$SCHEME" 2>/dev/null \
  | awk -F' = ' '/ MARKETING_VERSION = /{gsub(/ /,"",$2); print $2; exit}')"
VERSION="${VERSION:-0.0.0}"

echo "▶ Building $APP_NAME $VERSION (Release)…"
rm -rf "$DD"
xcodebuild build \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$DD" \
  CODE_SIGNING_ALLOWED=NO \
  | tail -n 3

APP="$DD/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || { echo "✗ Not found: $APP" >&2; exit 1; }

echo "▶ Ad-hoc signing (stable code signature, no Developer ID)…"
codesign --force --deep --sign - "$APP"

echo "▶ Preparing staging directory for the disk image…"
rm -rf "$STAGING"; mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"   # drag .app into Applications directly from the dmg

DMG="$BUILD_DIR/$APP_NAME-$VERSION.dmg"
rm -f "$DMG"
echo "▶ Creating ${DMG}…"
hdiutil create \
  -volname "$APP_NAME $VERSION" \
  -srcfolder "$STAGING" \
  -fs HFS+ -format UDZO -ov \
  "$DMG" >/dev/null

rm -rf "$STAGING"

echo "✓ Done: $DMG ($(du -h "$DMG" | cut -f1))"
echo "  To install on another machine: open the dmg → drag to Applications →"
echo "  remove quarantine: xattr -dr com.apple.quarantine /Applications/$APP_NAME.app"
