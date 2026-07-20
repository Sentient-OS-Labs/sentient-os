#!/bin/sh

set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 /path/to/Sentient\ OS.app" >&2
  exit 64
fi

APP="$1"
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
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

JQ="$(command -v jq || true)"
if [ -z "$JQ" ]; then
  echo "error: jq is required to verify Intel plugin metadata" >&2
  exit 1
fi
if [ ! -f "$PLUGIN_MCP" ]; then
  echo "error: Intel plugin .mcp.json is missing" >&2
  exit 1
fi
MCP_COMMAND="$($JQ -er '.mcpServers["computer-use"].command | select(type == "string")' "$PLUGIN_MCP" 2>/dev/null || true)"
if [ "$MCP_COMMAND" != "./bin/SentientComputerUseMCP" ]; then
  echo "error: Intel plugin command must be exactly ./bin/SentientComputerUseMCP" >&2
  exit 1
fi

if /usr/bin/grep -R -q 'SkyComputerUseService' "$INTEL_ROOT"; then
  echo "error: Intel plugin bundle references SkyComputerUseService" >&2
  exit 1
fi

# Reduce shared Swift sources to the branches compiled for x86_64 before checking permission
# routing. Sky remains present in #else branches for arm64, so a repository-wide grep would reject
# the correct dual-backend implementation.
ACTIVE_SOURCE="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/sentient-intel-source.XXXXXX")"
trap '/bin/rm -f "$ACTIVE_SOURCE"' EXIT HUP INT TERM

emit_intel_branch() {
  /usr/bin/awk '
    BEGIN { depth = 0; enabled[0] = 1 }
    /^[[:space:]]*#if[[:space:]]+/ {
      depth++
      parent[depth] = enabled[depth - 1]
      expression = $0
      if (expression ~ /arch\(x86_64\)/ && expression ~ /!arch\(x86_64\)/) {
        selected[depth] = 0; known[depth] = 1
      } else if (expression ~ /arch\(x86_64\)/) {
        selected[depth] = 1; known[depth] = 1
      } else if (expression ~ /arch\(arm64\)/) {
        selected[depth] = 0; known[depth] = 1
      } else {
        selected[depth] = 1; known[depth] = 0
      }
      enabled[depth] = parent[depth] && selected[depth]
      next
    }
    /^[[:space:]]*#else([[:space:]]|$)/ {
      if (known[depth]) selected[depth] = !selected[depth]
      enabled[depth] = parent[depth] && (known[depth] ? selected[depth] : 1)
      next
    }
    /^[[:space:]]*#elseif[[:space:]]+/ {
      expression = $0
      if (expression ~ /arch\(x86_64\)/ && expression !~ /!arch\(x86_64\)/) {
        selected[depth] = 1; known[depth] = 1
      } else if (expression ~ /arch\(x86_64\)/ || expression ~ /arch\(arm64\)/) {
        selected[depth] = 0; known[depth] = 1
      } else {
        selected[depth] = 1; known[depth] = 0
      }
      enabled[depth] = parent[depth] && selected[depth]
      next
    }
    /^[[:space:]]*#endif([[:space:]]|$)/ {
      delete parent[depth]; delete selected[depth]; delete known[depth]; delete enabled[depth]
      depth--
      next
    }
    enabled[depth] { print }
  ' "$1"
}

find "$ROOT/Sentient OS macOS" -name '*.swift' -type f -print | while IFS= read -r source; do
  emit_intel_branch "$source"
done > "$ACTIVE_SOURCE"

if /usr/bin/awk '
  /^[[:space:]]*\/\// { next }
  {
    line = $0
    sub(/\/\/.*/, "", line)
    if (line ~ /(grantComputerUseAutomation|revokeComputerUseAutomation|selfHealComputerUseAutomation)[[:space:]]*\(/ &&
        line !~ /func[[:space:]]+(grantComputerUseAutomation|revokeComputerUseAutomation|selfHealComputerUseAutomation)/) {
      print line
      found = 1
    }
  }
  END { exit found ? 0 : 1 }
' "$ACTIVE_SOURCE" >/dev/null; then
  echo "error: Intel source calls Sky Automation grant lifecycle" >&2
  exit 1
fi

if /usr/bin/awk '
  /^[[:space:]]*\/\// { next }
  { line = $0; sub(/\/\/.*/, "", line); if (line ~ /com\.openai\.sky\.CUAService/) found = 1 }
  END { exit found ? 0 : 1 }
' "$ACTIVE_SOURCE"; then
  echo "error: Intel permission routing gates on com.openai.sky.CUAService" >&2
  exit 1
fi

if ! /usr/bin/grep -F -q 'Accessibility is granted to Sentient OS' "$ACTIVE_SOURCE"; then
  echo "error: Intel Accessibility copy must name Sentient OS" >&2
  exit 1
fi
if ! /usr/bin/grep -F -q 'Screen Recording is granted to Sentient OS' "$ACTIVE_SOURCE"; then
  echo "error: Intel Screen Recording copy must name Sentient OS" >&2
  exit 1
fi
if ! /usr/bin/grep -F -q 'takes effect after you relaunch Sentient OS' "$ACTIVE_SOURCE"; then
  echo "error: Intel Screen Recording copy must explain the Sentient OS relaunch" >&2
  exit 1
fi

echo "Intel computer-use bundle verified: x86_64 binaries, Sentient MCP route, no Sky service reference"
