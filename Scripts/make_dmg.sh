#!/bin/bash
#
# make_dmg.sh — turn the notarized .app Xcode exported into the signed + notarized release DMG.
#
# YOU produce the input in Xcode (Archive → Distribute App → Direct Distribution → notarize →
# Export the notarized .app). This script takes that .app and does the rest:
#
#   sanity-check it (signed → notarized → stapled → real EdDSA key → Sparkle's Autoupdate helper
#   carries our team) → build the styled DMG (appdmg: background art + icon slots) → codesign the
#   DMG → notarize + staple the DMG itself → Gatekeeper-assess the result
#
# Output: build/dmg/SentientOS-<version>.dmg — hand it straight to release.sh.
#
#   ./make_dmg.sh "path/to/Sentient OS.app"
#
# ── ONE-TIME SETUP (notarizing the DMG needs its own credential; Xcode's login doesn't carry) ────
#   1. Create an app-specific password at https://account.apple.com → Sign-In and Security →
#      App-Specific Passwords.
#   2. xcrun notarytool store-credentials sentient-notary \
#        --apple-id <your Apple ID email> --team-id YJ8AZR3G5Q --password <that password>
#   The credential lives in this Mac's Keychain under the profile name; the script uses it forever.
#   (Override the profile name with NOTARY_PROFILE; SKIP_NOTARIZE=1 signs the DMG but skips
#   notarization — the stapled .app inside still satisfies Gatekeeper at first launch.)
#
# ── THE ART ──────────────────────────────────────────────────────────────────────────────────────
#   Scripts/dmg/background(.png|@2x.png) — vendored from the website repo, where the design
#   contract lives: sentient-os-website/DOCUMENTATION/07 - DMG Background (Compositor & Builder
#   Handoff).md. The window size and icon slots below were drawn INTO the art (halos + arc
#   endpoints sit under the icons) — if they ever change, change them there and here together.
#
# Doc: Sentient OS macOS/Documentation/Auto-Update (Sparkle).md (the release pipeline)
#
set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ART_DIR="$REPO_ROOT/Scripts/dmg"
BUILD_DIR="$REPO_ROOT/build/dmg"
TEAM_ID="YJ8AZR3G5Q"
NOTARY_PROFILE="${NOTARY_PROFILE:-sentient-notary}"
PLACEHOLDER_EDKEY="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

APP="${1:-}"
[[ -z "$APP" ]] && { echo "Usage: $0 \"path/to/Sentient OS.app\""; exit 1; }
[[ -d "$APP" && -f "$APP/Contents/Info.plist" ]] || { echo "❌ Not an .app bundle: $APP"; exit 1; }
command -v appdmg >/dev/null || { echo "❌ appdmg not found. npm install -g appdmg"; exit 1; }

SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
APP_NAME="$(basename "$APP")"

echo "──────────────────────────────────────────────────────────────────"
echo " Sentient OS DMG  ·  $APP_NAME  ·  version $SHORT ($BUILD)"
echo "──────────────────────────────────────────────────────────────────"

# ── 1. Sanity-check the input .app (catch every problem BEFORE the notary wait) ──────────────────
echo "→ [1/5] Sanity-checking the app…"
codesign --verify --deep --strict "$APP" || { echo "❌ Code signature is broken. Aborting."; exit 1; }

if ! ASSESS="$(spctl -a -t exec -vv "$APP" 2>&1)"; then
  echo "$ASSESS"; echo "❌ Gatekeeper REJECTED the app — not properly signed/notarized. Aborting."; exit 1
fi
echo "$ASSESS" | grep -q "Notarized" || {
  echo "$ASSESS"; echo "❌ App is signed but NOT notarized. Use Xcode's Direct Distribution first. Aborting."; exit 1; }
xcrun stapler validate "$APP" >/dev/null 2>&1 || {
  echo "❌ Notarization ticket is not stapled to the app (did you export BEFORE notarization finished?). Aborting."; exit 1; }

TEAM="$(codesign -dv --verbose=4 "$APP" 2>&1 | awk -F= '/TeamIdentifier/{print $2}')"
[[ "$TEAM" == "$TEAM_ID" ]] || { echo "❌ App team is '$TEAM', expected '$TEAM_ID'. Aborting."; exit 1; }

EDKEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist" 2>/dev/null || true)"
[[ "$EDKEY" == "$PLACEHOLDER_EDKEY" ]] && {
  echo "❌ This build carries the PLACEHOLDER EdDSA key — it could never verify updates. Aborting."; exit 1; }

# Sparkle's Autoupdate helper must carry OUR team or silent updates degrade to the non-atomic
# path (Auto-Update doc, gotchas). Debug builds leave it ad-hoc; a Developer ID export re-signs it.
AUTOUPDATE="$(find "$APP/Contents/Frameworks/Sparkle.framework" -type f -name Autoupdate 2>/dev/null | head -1)"
[[ -n "$AUTOUPDATE" ]] || { echo "❌ Sparkle's Autoupdate helper is missing from the bundle. Aborting."; exit 1; }
AU_TEAM="$(codesign -dv --verbose=4 "$AUTOUPDATE" 2>&1 | awk -F= '/TeamIdentifier/{print $2}')"
[[ "$AU_TEAM" == "$TEAM_ID" ]] || {
  echo "❌ Sparkle's Autoupdate helper is signed by '${AU_TEAM:-nobody}', not '$TEAM_ID' — silent"
  echo "   updates would degrade. Re-export via Xcode Direct Distribution (Embed & Sign). Aborting."; exit 1; }
echo "   ✅ signed · notarized · stapled · real EdDSA key · Autoupdate team $AU_TEAM"

# ── 2. Build the styled DMG (appdmg writes the .DS_Store directly — no Finder scripting) ─────────
echo "→ [2/5] Building the DMG…"
[[ -f "$ART_DIR/background.png" && -f "$ART_DIR/background@2x.png" ]] || {
  echo "❌ Background art missing at $ART_DIR (background.png + background@2x.png). Aborting."; exit 1; }
rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
DMG="$BUILD_DIR/SentientOS-$SHORT.dmg"

# The geometry contract (window 680×440 · slots (190,105)/(490,105) · icon 100) is the one the
# art was drawn around — see the handoff doc referenced in the header before changing anything.
cat > "$BUILD_DIR/appdmg.json" <<JSON
{
  "title": "Sentient OS",
  "background": "$ART_DIR/background.png",
  "icon-size": 100,
  "format": "UDZO",
  "window": { "position": { "x": 400, "y": 180 }, "size": { "width": 680, "height": 440 } },
  "contents": [
    { "x": 190, "y": 105, "type": "file", "path": "$APP" },
    { "x": 490, "y": 105, "type": "link", "path": "/Applications" }
  ]
}
JSON
appdmg "$BUILD_DIR/appdmg.json" "$DMG"

# ── 3. Sign the DMG ──────────────────────────────────────────────────────────────────────────────
echo "→ [3/5] Signing the DMG…"
IDENTITY="$(security find-identity -v -p codesigning | awk -v t="$TEAM_ID" -F'"' '$2 ~ /Developer ID Application/ && $2 ~ t {print $2; exit}')"
[[ -n "$IDENTITY" ]] || { echo "❌ No 'Developer ID Application' identity for team $TEAM_ID in the Keychain. Aborting."; exit 1; }
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
echo "   signed as: $IDENTITY"

# ── 4. Notarize + staple the DMG itself (the app inside is already stapled; this blesses the
#       container too — Apple's recommended shape for internet downloads) ─────────────────────────
if [[ -n "${SKIP_NOTARIZE:-}" ]]; then
  echo "→ [4/5] Skipping DMG notarization (SKIP_NOTARIZE set)."
else
  echo "→ [4/5] Notarizing the DMG (Apple's robots, usually 2–10 min)…"
  set +e
  NOTARY_OUT="$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"
  NOTARY_RC=$?
  set -e
  echo "$NOTARY_OUT" | sed 's/^/   /'
  if [[ $NOTARY_RC -ne 0 || "$(grep -c 'status: Accepted' <<<"$NOTARY_OUT")" -eq 0 ]]; then
    SUB_ID="$(awk '/^ *id: /{print $2; exit}' <<<"$NOTARY_OUT")"
    echo "❌ DMG notarization did not come back Accepted."
    [[ -n "$SUB_ID" ]] && echo "   Why: xcrun notarytool log $SUB_ID --keychain-profile $NOTARY_PROFILE"
    grep -q "No Keychain password item found" <<<"$NOTARY_OUT" && {
      echo "   Looks like the one-time credential setup hasn't been done — see the header of this script."; }
    echo "   Aborting."; exit 1
  fi
  xcrun stapler staple "$DMG" >/dev/null || { echo "❌ Stapling the DMG failed. Aborting."; exit 1; }
  xcrun stapler validate "$DMG" >/dev/null || { echo "❌ Stapled ticket didn't validate. Aborting."; exit 1; }
  echo "   ✅ notarized + stapled"
fi

# ── 5. Final Gatekeeper assessment of the finished DMG ───────────────────────────────────────────
echo "→ [5/5] Gatekeeper assessment…"
spctl -a -t open --context context:primary-signature -v "$DMG" 2>&1 | sed 's/^/   /'

echo "──────────────────────────────────────────────────────────────────"
echo " ✅ $DMG"
echo ""
echo " NEXT:  ./Scripts/release.sh \"$DMG\""
echo "──────────────────────────────────────────────────────────────────"
