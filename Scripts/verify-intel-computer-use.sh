#!/bin/sh

set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 /path/to/Sentient\ OS.app" >&2
  exit 64
fi

APP="$1"
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
SOURCE_ROOT="${SENTIENT_INTEL_SOURCE_ROOT:-$ROOT/Sentient OS macOS}"
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

# Audit the compiled app, not just shared source. Debug builds put most Swift code in a dylib next
# to the launcher, so inspect every Mach-O under Contents/MacOS.
APP_MACOS="$APP/Contents/MacOS"
found_app_binary=false
for binary in "$APP_MACOS"/*; do
  [ -f "$binary" ] || continue
  if ! /usr/bin/file "$binary" | /usr/bin/grep -q 'Mach-O'; then continue; fi
  found_app_binary=true
  if /usr/bin/strings -a "$binary" | /usr/bin/grep -q 'com\.openai\.sky\.CUAService'; then
    echo "error: Intel app binary contains the Sky permission-owner bundle identifier" >&2
    exit 1
  fi
  if /usr/bin/nm -j "$binary" 2>/dev/null \
      | /usr/bin/xcrun swift-demangle 2>/dev/null \
      | /usr/bin/grep -E -q 'Permissions\.(grantComputerUseAutomation|revokeComputerUseAutomation|selfHealComputerUseAutomation)'; then
    echo "error: Intel app binary contains Sky Automation lifecycle symbols" >&2
    exit 1
  fi
done
if [ "$found_app_binary" != true ]; then
  echo "error: Intel app contains no auditable Mach-O under Contents/MacOS" >&2
  exit 1
fi

# Reduce shared Swift sources to the branches compiled for x86_64 before checking permission
# routing. Sky remains present in #else branches for arm64, so a repository-wide grep would reject
# the correct dual-backend implementation.
ACTIVE_SOURCE="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/sentient-intel-source.XXXXXX")"
ACTIVE_PERMISSIONS="${ACTIVE_SOURCE}.permissions"
ACTIVE_GATE_VIEW="${ACTIVE_SOURCE}.gate"
ACTIVE_HEALTH_VIEW="${ACTIVE_SOURCE}.health"
trap '/bin/rm -f "$ACTIVE_SOURCE" "$ACTIVE_PERMISSIONS" "$ACTIVE_GATE_VIEW" "$ACTIVE_HEALTH_VIEW"' EXIT HUP INT TERM

emit_intel_branch() {
  /usr/bin/awk '
    function intel_condition(directive, expression) {
      expression = directive
      sub(/^[[:space:]]*#(if|elseif)[[:space:]]+/, "", expression)
      gsub(/[[:space:]]/, "", expression)
      if (expression == "arch(x86_64)")  return 1
      if (expression == "!arch(x86_64)") return 0
      if (expression == "arch(arm64)")   return 0
      if (expression == "!arch(arm64)")  return 1
      return -1
    }
    BEGIN { depth = 0; enabled[0] = 1 }
    /^[[:space:]]*#if[[:space:]]+/ {
      depth++
      parent[depth] = enabled[depth - 1]
      condition = intel_condition($0)
      known[depth] = condition >= 0
      taken[depth] = condition == 1
      enabled[depth] = parent[depth] && (known[depth] ? condition : 1)
      next
    }
    /^[[:space:]]*#else([[:space:]]|$)/ {
      enabled[depth] = parent[depth] && (known[depth] ? !taken[depth] : 1)
      taken[depth] = 1
      next
    }
    /^[[:space:]]*#elseif[[:space:]]+/ {
      condition = intel_condition($0)
      if (!known[depth] || condition < 0) {
        known[depth] = 0
        enabled[depth] = parent[depth]
      } else {
        enabled[depth] = parent[depth] && !taken[depth] && condition
        if (condition) taken[depth] = 1
      }
      next
    }
    /^[[:space:]]*#endif([[:space:]]|$)/ {
      delete parent[depth]; delete taken[depth]; delete known[depth]; delete enabled[depth]
      depth--
      next
    }
    enabled[depth] { print }
  ' "$1"
}

find "$SOURCE_ROOT" -name '*.swift' -type f -print | while IFS= read -r source; do
  emit_intel_branch "$source"
done > "$ACTIVE_SOURCE"
emit_intel_branch "$SOURCE_ROOT/System/Permissions.swift" > "$ACTIVE_PERMISSIONS"
emit_intel_branch "$SOURCE_ROOT/Views/Permissions/ComputerUseGateView.swift" > "$ACTIVE_GATE_VIEW"
emit_intel_branch "$SOURCE_ROOT/Views/Settings/HealthPane.swift" > "$ACTIVE_HEALTH_VIEW"

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

if ! /usr/bin/grep -F -q \
    'static func hasComputerUseScreenRecording() -> Bool { CGPreflightScreenCaptureAccess() }' \
    "$ACTIVE_PERMISSIONS"; then
  echo "error: Intel Screen Recording readiness must use current-process CGPreflight only" >&2
  exit 1
fi

gate_screen_rows="$(/usr/bin/grep -F -c 'StatusLine(title: "Screen Recording' "$ACTIVE_GATE_VIEW" || true)"
health_screen_rows="$(/usr/bin/grep -F -c 'StatusLine(title: "Screen Recording' "$ACTIVE_HEALTH_VIEW" || true)"
if [ "$gate_screen_rows" -ne 1 ] || [ "$health_screen_rows" -ne 1 ]; then
  echo "error: Intel Gate and Health must each show exactly one Screen Recording row" >&2
  exit 1
fi

if ! /usr/bin/grep -F -q 'helperScreenRelaunchRequired' "$ACTIVE_GATE_VIEW" \
    || ! /usr/bin/grep -F -q 'Permissions.relaunch()' "$ACTIVE_GATE_VIEW"; then
  echo "error: Intel gate must keep Screen Recording blocked and offer relaunch when needed" >&2
  exit 1
fi
if ! /usr/bin/grep -F -q 'helperScreenRecordingRelaunchRequired' "$ACTIVE_HEALTH_VIEW" \
    || ! /usr/bin/grep -F -q 'Permissions.relaunch()' "$ACTIVE_HEALTH_VIEW"; then
  echo "error: Intel Health must show Screen Recording relaunch-required state and action" >&2
  exit 1
fi

echo "Intel computer-use bundle verified: x86_64 binaries, Sentient MCP route, no Sky service reference"
