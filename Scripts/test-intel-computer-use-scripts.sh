#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
MODE="${1:-all}"
TEMP_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/sentient-cu-scripts.XXXXXX")"
trap 'find "$TEMP_DIR" -depth -delete' EXIT HUP INT TERM

test_corrupted_command() {
  app="$TEMP_DIR/Sentient OS.app"
  intel="$app/Contents/Resources/IntelComputerUse"
  /bin/mkdir -p "$intel/bin"
  /usr/bin/xcrun clang -arch x86_64 "$ROOT/Scripts/Tests/empty.c" -o "$intel/bin/SentientComputerUseMCP"
  /bin/cp "$intel/bin/SentientComputerUseMCP" "$intel/bin/SentientComputerUseService"
  /bin/cp "$ROOT/Scripts/Tests/valid.mcp.json" "$intel/.mcp.json"
  "$ROOT/Scripts/verify-intel-computer-use.sh" "$app"

  /bin/cp "$ROOT/Scripts/Tests/corrupt-command.mcp.json" "$intel/.mcp.json"
  if "$ROOT/Scripts/verify-intel-computer-use.sh" "$app"; then
    echo "FAIL: verifier accepted a non-exact MCP command" >&2
    exit 1
  fi
  echo "Corrupted MCP command fixture rejected"
}

test_stale_cleanup() {
  build_dir="$TEMP_DIR/build"
  resources="Sentient OS.app/Contents/Resources"
  stale="$build_dir/$resources/IntelComputerUse"
  /bin/mkdir -p "$stale"
  /usr/bin/touch "$stale/stale"

  ARCHS=arm64 \
  BUILD_INTEL_COMPUTER_USE=NO \
  SRCROOT="$ROOT" \
  TARGET_BUILD_DIR="$build_dir" \
  UNLOCALIZED_RESOURCES_FOLDER_PATH="$resources" \
    "$ROOT/Scripts/build-intel-computer-use.sh"

  if [ -e "$stale" ]; then
    echo "FAIL: non-x86_64 build left stale IntelComputerUse resources" >&2
    exit 1
  fi
  echo "Stale non-x86_64 bundle fixture cleaned"
}

case "$MODE" in
  corrupted-command) test_corrupted_command ;;
  stale-cleanup) test_stale_cleanup ;;
  all) test_corrupted_command; test_stale_cleanup ;;
  *) echo "usage: $0 [corrupted-command|stale-cleanup|all]" >&2; exit 64 ;;
esac
