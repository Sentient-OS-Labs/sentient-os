#!/bin/sh

set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 /path/to/Sentient\ OS.app" >&2
  exit 64
fi

APP="$1"
INTEL_ROOT="$APP/Contents/Resources/IntelComputerUse"
MCP="$INTEL_ROOT/bin/SentientComputerUseMCP"
SERVICE="$INTEL_ROOT/bin/SentientComputerUseService"
PLUGIN_MCP="$INTEL_ROOT/.mcp.json"

if [ ! -d "$INTEL_ROOT" ]; then
  echo "error: Intel computer-use bundle not found: $INTEL_ROOT" >&2
  exit 1
fi

for executable in "$MCP" "$SERVICE"; do
  if [ ! -x "$executable" ]; then
    echo "error: bundled executable missing or not executable: $executable" >&2
    exit 1
  fi

  architectures="$(/usr/bin/lipo -archs "$executable" 2>/dev/null || true)"
  if [ "$architectures" != "x86_64" ]; then
    echo "error: expected x86_64-only executable at $executable; found: ${architectures:-not Mach-O}" >&2
    exit 1
  fi
done

if [ ! -f "$PLUGIN_MCP" ] || ! /usr/bin/grep -q 'SentientComputerUseMCP' "$PLUGIN_MCP"; then
  echo "error: Intel plugin .mcp.json does not reference SentientComputerUseMCP" >&2
  exit 1
fi

if /usr/bin/grep -R -q 'SkyComputerUseService' "$INTEL_ROOT"; then
  echo "error: Intel plugin bundle references SkyComputerUseService" >&2
  exit 1
fi

echo "Intel computer-use bundle verified: x86_64 binaries, Sentient MCP route, no Sky service reference"
