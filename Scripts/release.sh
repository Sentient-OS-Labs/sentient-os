#!/bin/bash
#
# release.sh — publish an already signed + notarized Sentient OS DMG for Sparkle auto-update.
#
# The DMG comes from make_dmg.sh (you export the notarized .app in Xcode; it builds, signs,
# notarizes + staples the DMG — see its header). This script takes that finished DMG and does
# the rest:
#
#   validate it's really notarized → verify its dSYMs are on Sentry → EdDSA-sign → generate
#   appcast → GitHub Release → Homebrew cask
#
# Run on JESAI'S Mac: the EdDSA private seed lives in THIS Mac's login Keychain, and the GitHub
# release + cask push ride the already-authed `gh`. Notarization is NOT done here (you do it in
# Xcode), so there are NO notary credentials to set up.
#
# ── ONE-TIME SETUP (done) ─────────────────────────────────────────────────────────────────────
#   EdDSA key:  ./release.sh keys   → prints SUPublicEDKey (already baked into ../Info.plist).
#               Minted 2026-07-07; private seed stays in the Keychain, NEVER in the repo.
#               ✅ Seed backed up off-machine 2026-07-18 (shared 1Password vault).
#   Sparkle CLI tools resolve automatically from the SwiftPM checkout in DerivedData (or set
#   SPARKLE_BIN, or `brew install --cask sparkle`).
#
# ── EACH RELEASE ──────────────────────────────────────────────────────────────────────────────
#   1. Bump MARKETING_VERSION + CURRENT_PROJECT_VERSION (the build number MUST increase — Sparkle
#      compares CFBundleVersion). Archive → Distribute (Direct Distribution) → Export Notarized App.
#   2. ./make_dmg.sh "path/to/Sentient OS.app"   →   ./release.sh build/dmg/SentientOS-<version>.dmg
#   3. Publish the emitted appcast.xml to https://sentient-os.ai/appcast.xml (the script prints how).
#
# Doc: Sentient OS macOS/Documentation/Auto-Update (Sparkle).md
#
set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"          # the app git repo root (has the .xcodeproj)
APP_NAME="Sentient OS"
BUILD_DIR="$REPO_ROOT/build/release"
GH_REPO="${GH_REPO:-Sentient-OS-Labs/sentient-os}"     # public repo — the production default (override for dry runs)
WEB_REPO="Sentient-OS-Labs/sentient-os-website"         # serves public/appcast.xml via Vercel
TAP_REPO="${TAP_REPO:-Sentient-OS-Labs/homebrew-tap}"   # the Homebrew cask lives here (Casks/sentient-os.rb)
KEYCHAIN_ACCOUNT="${KEYCHAIN_ACCOUNT:-ed25519}"        # Sparkle EdDSA Keychain account
TEAM_ID="YJ8AZR3G5Q"                                    # Sparkle requires updates to match the installed team
PLACEHOLDER_EDKEY="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

# ── Locate Sparkle's CLI tools (generate_keys / sign_update / generate_appcast) ──────────────────
find_sparkle_bin() {
  if [[ -n "${SPARKLE_BIN:-}" && -x "$SPARKLE_BIN/sign_update" ]]; then echo "$SPARKLE_BIN"; return; fi
  for c in /Applications/Sparkle.app/Contents/Resources \
           /opt/homebrew/Caskroom/sparkle/*/bin \
           /usr/local/Caskroom/sparkle/*/bin; do
    [[ -x "$c/sign_update" ]] && { echo "$c"; return; }
  done
  local found
  found="$(find "$HOME/Library/Developer/Xcode/DerivedData" -type f -name sign_update -path '*Sparkle*' ! -path '*old_dsa_scripts*' 2>/dev/null | head -1)"
  [[ -n "$found" ]] && { dirname "$found"; return; }
  echo ""
}

# ── Bump the Homebrew cask in our own tap (version + sha256 → commit → push) ──────────────────────
# Stateless: clones the tap fresh, rewrites the two values, pushes via the already-authed gh.
# Best-effort — a failure never unwinds an already-published release. Uses $DMG / $SHORT / $BUILD_DIR.
bump_cask() {
  local sha tap_dir cask
  sha="$(shasum -a 256 "$DMG" | awk '{print $1}')"
  tap_dir="$BUILD_DIR/tap"; rm -rf "$tap_dir"
  gh repo clone "$TAP_REPO" "$tap_dir" -- --depth 1 --quiet || return 1
  cask="$tap_dir/Casks/sentient-os.rb"
  [[ -f "$cask" ]] || { echo "   cask file missing in $TAP_REPO"; return 1; }
  /usr/bin/perl -i -pe "s|^  version \".*\"|  version \"$SHORT\"|" "$cask"
  /usr/bin/perl -i -pe "s|^  sha256 \".*\"|  sha256 \"$sha\"|"     "$cask"
  grep -q "$sha" "$cask" || { echo "   cask sha256 rewrite failed"; return 1; }
  git -C "$tap_dir" diff --quiet && { echo "   cask already at $SHORT — nothing to push"; return 0; }
  git -C "$tap_dir" commit -aqm "sentient-os $SHORT" && git -C "$tap_dir" push --quiet || return 1
  echo "   cask → sentient-os $SHORT  (sha256 $sha)"
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

# ── Input: the pre-notarized DMG ─────────────────────────────────────────────────────────────────
INPUT_DMG="${1:-}"
[[ -z "$INPUT_DMG" ]] && { echo "Usage: $0 path/to/SentientOS-<version>.dmg   (or: $0 keys)"; exit 1; }
[[ -f "$INPUT_DMG" ]] || { echo "❌ No DMG at: $INPUT_DMG"; exit 1; }

BIN="$(find_sparkle_bin)"
[[ -z "$BIN" ]] && { echo "❌ Sparkle tools not found. brew install --cask sparkle (or set SPARKLE_BIN)."; exit 1; }

echo "──────────────────────────────────────────────────────────────────"
echo " Sentient OS release  ·  input: $INPUT_DMG"
echo " tools: $BIN"
echo "──────────────────────────────────────────────────────────────────"
rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"

# ── 1. Mount, VALIDATE (signed + notarized + stapled), read the shipped version ──────────────────
echo "→ [1/6] Validating the DMG and reading its version…"
MOUNT="$(mktemp -d)"
hdiutil attach "$INPUT_DMG" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null
trap 'hdiutil detach "$MOUNT" >/dev/null 2>&1 || true' EXIT

APP="$(find "$MOUNT" -maxdepth 1 -name '*.app' | head -1)"
[[ -n "$APP" ]] || { echo "❌ No .app inside the DMG."; exit 1; }

# Gatekeeper assessment — must be accepted AND notarized (not merely Developer-ID signed).
if ! ASSESS="$(spctl -a -t exec -vv "$APP" 2>&1)"; then
  echo "$ASSESS"; echo "❌ Gatekeeper REJECTED the app — not properly signed/notarized. Aborting."; exit 1
fi
echo "$ASSESS" | grep -q "Notarized" || {
  echo "$ASSESS"; echo "❌ App is signed but NOT notarized. Notarize + staple before releasing. Aborting."; exit 1; }
xcrun stapler validate "$APP" >/dev/null 2>&1 || {
  echo "❌ Notarization ticket is not stapled to the app. Aborting."; exit 1; }

TEAM="$(codesign -dv --verbose=4 "$APP" 2>&1 | awk -F= '/TeamIdentifier/{print $2}')"
[[ "$TEAM" == "$TEAM_ID" ]] || echo "   ⚠️  Team is '$TEAM', expected '$TEAM_ID' — Sparkle needs the SAME team as the installed app."

SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
EDKEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist" 2>/dev/null || true)"

# The binary's UUIDs (one per arch) — read while mounted; step 2 matches dSYMs against them.
EXEC_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
APP_UUIDS="$(dwarfdump --uuid "$APP/Contents/MacOS/$EXEC_NAME" | awk '{print $2}')"
[[ -n "$APP_UUIDS" ]] || { echo "❌ Couldn't read the app binary's UUIDs. Aborting."; exit 1; }
[[ "$EDKEY" == "$PLACEHOLDER_EDKEY" ]] && {
  echo "❌ This build carries the PLACEHOLDER EdDSA key — it could never verify updates. Rebuild with the real key. Aborting."; exit 1; }

hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
trap - EXIT
echo "   ✅ notarized · team $TEAM · version $SHORT ($BUILD)"

# ── 2. Ensure THIS build's crash symbols (dSYMs) are on Sentry ────────────────────────────────────
# The Xcode build phase uploads dSYMs at Archive time but fails SILENTLY by design (OSS clones
# must build without our token). This is the loud seatbelt: find the local dSYMs matching the
# DMG's binary UUIDs and (re-)upload them — idempotent, sentry-cli skips what the server has.
# No symbols = every crash from this build is unreadable FOREVER (the beta-wave failure), so a
# miss ABORTS the release. Doc: Documentation/Crash Reporting (Sentry).md
if [[ -n "${SKIP_SENTRY:-}" ]]; then
  echo "→ [2/6] Skipping the Sentry symbol check (SKIP_SENTRY set)."
else
  echo "→ [2/6] Verifying this build's crash symbols are on Sentry…"
  command -v sentry-cli >/dev/null || { echo "❌ sentry-cli not found (brew install getsentry/tools/sentry-cli), or SKIP_SENTRY=1 to knowingly release without crash symbols. Aborting."; exit 1; }
  [[ -f "$REPO_ROOT/.sentryclirc" || -n "${SENTRY_AUTH_TOKEN:-}" ]] || { echo "❌ No .sentryclirc at $REPO_ROOT and no SENTRY_AUTH_TOKEN — can't talk to Sentry. Aborting."; exit 1; }
  DSYM_DIR=""
  for d in "${DSYM_SEARCH:-$HOME/Library/Developer/Xcode/Archives}"/*/*.xcarchive/dSYMs; do
    [[ -d "$d" ]] || continue
    have="$(find "$d" -type f -path '*/Resources/DWARF/*' -exec dwarfdump --uuid {} + 2>/dev/null | awk '{print $2}')"
    all=1
    while read -r u; do grep -Fqxi "$u" <<<"$have" || { all=0; break; }; done <<<"$APP_UUIDS"
    [[ $all == 1 ]] && { DSYM_DIR="$d"; break; }
  done
  [[ -n "$DSYM_DIR" ]] || {
    echo "❌ No local dSYMs match this DMG's binary UUIDs:"
    sed 's/^/     /' <<<"$APP_UUIDS"
    echo "   Searched ~/Library/Developer/Xcode/Archives (override the root: DSYM_SEARCH=<dir>)."
    echo "   Was this DMG archived on this Mac? Without its dSYM every crash it ever has is"
    echo "   unreadable, permanently. Not shipping that. Aborting."; exit 1; }
  echo "   dSYMs: $DSYM_DIR"
  (cd "$REPO_ROOT" && sentry-cli debug-files upload --include-sources "$DSYM_DIR") || {
    echo "❌ Sentry symbol upload failed. Aborting."; exit 1; }
  echo "   ✅ symbols on Sentry for $SHORT ($BUILD)"
fi

TAG="$SHORT"
STAGE="$BUILD_DIR/appcast"; mkdir -p "$STAGE"
DMG="$STAGE/SentientOS-$SHORT.dmg"      # canonical, space-free asset name → clean appcast URLs
cp "$INPUT_DMG" "$DMG"

# ── 3. EdDSA-sign the DMG (explicit — generate_appcast re-signs, this prints + verifies the sig) ──
echo "→ [3/6] EdDSA-signing the DMG…"
"$BIN/sign_update" "$DMG" --account "$KEYCHAIN_ACCOUNT"

# ── 4. Generate the appcast (enclosure URL points at the GitHub Release asset) ────────────────────
echo "→ [4/6] Generating appcast…"
FEED_PREFIX="https://github.com/$GH_REPO/releases/download/$TAG/"
"$BIN/generate_appcast" "$STAGE" \
  --account "$KEYCHAIN_ACCOUNT" \
  --download-url-prefix "$FEED_PREFIX" \
  -o "$STAGE/appcast.xml"
echo "   appcast → $STAGE/appcast.xml"

# ── 5. GitHub Release (uploads the DMG the appcast points at) ─────────────────────────────────────
echo "→ [5/6] Creating GitHub release ${TAG}…"
gh release create "$TAG" "$DMG" \
  --repo "$GH_REPO" --title "$APP_NAME $SHORT" \
  --notes "Sentient OS $SHORT ($BUILD)" || \
  echo "   (release may already exist — upload manually with: gh release upload $TAG \"$DMG\")"

# ── 6. Bump + push the Homebrew cask (own tap) ────────────────────────────────────────────────────
if [[ -n "${SKIP_CASK:-}" ]]; then
  echo "→ [6/6] Skipping Homebrew cask bump (SKIP_CASK set)."
else
  echo "→ [6/6] Updating Homebrew cask…"
  bump_cask || echo "   ⚠️  cask bump failed — update $TAP_REPO/Casks/sentient-os.rb by hand (version \"$SHORT\" + the sha256 of $DMG), then push."
fi

echo "──────────────────────────────────────────────────────────────────"
echo " ✅ Signed, appcast'd, released, cask-bumped: $APP_NAME $SHORT ($BUILD)."
echo ""
echo " NEXT (manual, load-bearing), in ONE website clone: publish the appcast so installed apps"
echo " see the update, AND bump the site's Download button (its direct-DMG URL is version-pinned"
echo " in components/close/DownloadScene.tsx). Vercel auto-deploys main:"
echo ""
echo "     gh repo clone $WEB_REPO /tmp/sos-web -- --depth 1"
echo "     cp \"$STAGE/appcast.xml\" /tmp/sos-web/public/appcast.xml"
echo "     perl -i -pe 's|releases/download/[^\\\"]*\\.dmg|releases/download/$TAG/SentientOS-$SHORT.dmg|' /tmp/sos-web/components/close/DownloadScene.tsx"
echo "     git -C /tmp/sos-web commit -aqm \"release: $APP_NAME $SHORT (appcast + download URL)\" && git -C /tmp/sos-web push"
echo ""
echo "   Then verify:  curl -s https://sentient-os.ai/appcast.xml | head"
echo "──────────────────────────────────────────────────────────────────"
