#!/usr/bin/env bash
# Ad-hoc dev build of Sentient OS: build → quit any running copy → install to /Applications → relaunch.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Sentient OS"
APP_SOURCE="$ROOT/build/Build/Products/Debug/$APP_NAME.app"
APP_DEST="/Applications/$APP_NAME.app"

cd "$ROOT"

echo "▸ Building (Debug, ad-hoc)…"
xcodebuild \
  -project "Sentient OS macOS.xcodeproj" \
  -scheme "Sentient OS macOS" \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM= \
  -allowProvisioningUpdates \
  build

echo "▸ Quitting any running copy…"
osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || pkill -f "$APP_NAME" 2>/dev/null || true
sleep 1

echo "▸ Installing to /Applications…"
rm -rf "$APP_DEST"
cp -R "$APP_SOURCE" "$APP_DEST"
xattr -dr com.apple.quarantine "$APP_DEST" 2>/dev/null || true

echo "▸ Launching…"
open "$APP_DEST"

echo "✓ Done."
