#!/bin/bash
#
# release.sh — cut a signed, notarized Sentient OS release and publish it for Sparkle auto-update.
#
# The whole pipeline, one command:
#   archive → export (Developer ID) → DMG → notarize → staple → EdDSA-sign → appcast → GitHub Release
#
# Run this on JESAI'S Mac (the paid Developer-ID team YJ8AZR3G5Q) — Sparkle requires every update to
# be signed with the SAME Team ID as the installed app, and only the paid account can notarize.
#
# ── ONE-TIME SETUP (do these once, ever) ────────────────────────────────────────────────────────
#   1. EdDSA signing key:      ./release.sh keys
#        → prints SUPublicEDKey. Paste it into ../Info.plist (replacing the placeholder), commit.
#        → the private seed is stored in this Mac's login Keychain; NEVER put it in the repo.
#   2. Notary credentials:     xcrun notarytool store-credentials "SentientNotary" \
#                                --apple-id "you@apple.id" --team-id YJ8AZR3G5Q --password <app-specific-pw>
#   3. Sparkle CLI tools:      brew install --cask sparkle   (or set SPARKLE_BIN to a Sparkle bin/ dir)
#
# ── EACH RELEASE ────────────────────────────────────────────────────────────────────────────────
#   1. Bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in the project (build number MUST increase —
#      Sparkle compares CFBundleVersion). Commit.
#   2. ./release.sh            (reads the version from the build)
#   3. Publish the emitted appcast.xml to https://sentient-os.ai/appcast.xml (the SUFeedURL).
#
# Doc: Sentient OS macOS/Documentation/Auto-Update (Sparkle).md
#
set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"          # the app git repo root (has the .xcodeproj)
PROJECT="$REPO_ROOT/Sentient OS macOS.xcodeproj"
SCHEME="Sentient OS macOS"
APP_NAME="Sentient OS"
BUILD_DIR="$REPO_ROOT/build/release"
GH_REPO="Sentient-OS-Labs/sentient-os"
NOTARY_PROFILE="${NOTARY_PROFILE:-SentientNotary}"     # xcrun notarytool keychain profile name
DEVELOPER_ID="${DEVELOPER_ID:-Developer ID Application}" # matched from the keychain by prefix
KEYCHAIN_ACCOUNT="${KEYCHAIN_ACCOUNT:-ed25519}"        # Sparkle EdDSA Keychain account

# ── Locate Sparkle's CLI tools (generate_keys / sign_update / generate_appcast) ──────────────────
find_sparkle_bin() {
  if [[ -n "${SPARKLE_BIN:-}" && -x "$SPARKLE_BIN/sign_update" ]]; then echo "$SPARKLE_BIN"; return; fi
  # Homebrew cask lays them into the Sparkle.app or a caskroom bin.
  for c in /Applications/Sparkle.app/Contents/Resources \
           /opt/homebrew/Caskroom/sparkle/*/bin \
           /usr/local/Caskroom/sparkle/*/bin; do
    [[ -x "$c/sign_update" ]] && { echo "$c"; return; }
  done
  # Fall back to the resolved SwiftPM artifact in DerivedData.
  local found
  found="$(find "$HOME/Library/Developer/Xcode/DerivedData" -type f -name sign_update -path '*Sparkle*' 2>/dev/null | head -1)"
  [[ -n "$found" ]] && { dirname "$found"; return; }
  echo ""
}

# ── Subcommand: one-time key generation ──────────────────────────────────────────────────────────
if [[ "${1:-}" == "keys" ]]; then
  BIN="$(find_sparkle_bin)"
  [[ -z "$BIN" ]] && { echo "❌ Sparkle tools not found. brew install --cask sparkle (or set SPARKLE_BIN)."; exit 1; }
  echo "→ Generating / reading the EdDSA key (private seed stays in this Mac's Keychain)…"
  "$BIN/generate_keys" --account "$KEYCHAIN_ACCOUNT"
  echo ""
  echo "☝️  Copy the SUPublicEDKey <string> above into $REPO_ROOT/Info.plist (replace the placeholder)."
  exit 0
fi

BIN="$(find_sparkle_bin)"
[[ -z "$BIN" ]] && { echo "❌ Sparkle tools not found. brew install --cask sparkle (or set SPARKLE_BIN)."; exit 1; }

echo "──────────────────────────────────────────────────────────────────"
echo " Sentient OS release  ·  tools: $BIN"
echo "──────────────────────────────────────────────────────────────────"
rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"

# ── 1. Archive (Release, Developer ID via Signing.xcconfig) ──────────────────────────────────────
echo "→ [1/7] Archiving…"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -archivePath "$ARCHIVE" archive | xcbeautify 2>/dev/null || \
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -archivePath "$ARCHIVE" archive

# ── 2. Export a Developer-ID-signed .app ─────────────────────────────────────────────────────────
echo "→ [2/7] Exporting (Developer ID)…"
cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" -exportPath "$EXPORT_DIR"

APP="$EXPORT_DIR/$APP_NAME.app"
[[ -d "$APP" ]] || { echo "❌ Export produced no .app at $APP"; exit 1; }

# Version from the built app (source of truth = what actually shipped).
SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
TAG="$SHORT"
DMG="$BUILD_DIR/SentientOS-$SHORT.dmg"      # no spaces in the asset name (appcast URL encoding)
echo "   version $SHORT ($BUILD) → tag $TAG"

# ── 3. Build a DMG (Applications drag-target) ────────────────────────────────────────────────────
echo "→ [3/7] Building DMG…"
STAGE="$BUILD_DIR/dmg"; rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

# ── 4. Notarize + 5. Staple ──────────────────────────────────────────────────────────────────────
echo "→ [4/7] Notarizing (this waits on Apple)…"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
echo "→ [5/7] Stapling…"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# ── 6. EdDSA-sign the DMG for Sparkle + generate the appcast ─────────────────────────────────────
echo "→ [6/7] Signing (EdDSA) + generating appcast…"
"$BIN/sign_update" "$DMG" --account "$KEYCHAIN_ACCOUNT"    # prints edSignature (also folded into appcast)
FEED_PREFIX="https://github.com/$GH_REPO/releases/download/$TAG/"
"$BIN/generate_appcast" "$BUILD_DIR" \
  --account "$KEYCHAIN_ACCOUNT" \
  --download-url-prefix "$FEED_PREFIX" \
  -o "$BUILD_DIR/appcast.xml"
echo "   appcast → $BUILD_DIR/appcast.xml"

# ── 7. GitHub Release (uploads the DMG the appcast points at) ────────────────────────────────────
echo "→ [7/7] Creating GitHub release $TAG…"
gh release create "$TAG" "$DMG" \
  --repo "$GH_REPO" --title "$APP_NAME $SHORT" \
  --notes "Sentient OS $SHORT ($BUILD)" || \
  echo "   (release may already exist — upload manually with: gh release upload $TAG \"$DMG\")"

echo "──────────────────────────────────────────────────────────────────"
echo " ✅ Built, notarized, signed, and released $APP_NAME $SHORT."
echo ""
echo " NEXT (manual, load-bearing): publish the appcast so installed apps see the update —"
echo "   copy  $BUILD_DIR/appcast.xml"
echo "   to    https://sentient-os.ai/appcast.xml   (the SUFeedURL every build polls)."
echo "──────────────────────────────────────────────────────────────────"
