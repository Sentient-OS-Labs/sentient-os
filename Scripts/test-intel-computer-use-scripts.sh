#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
MODE="${1:-all}"
TEMP_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/sentient-cu-scripts.XXXXXX")"
trap 'find "$TEMP_DIR" -depth -delete' EXIT HUP INT TERM

make_valid_app() {
  app="$1"
  intel="$app/Contents/Resources/IntelComputerUse"
  plugin="$intel/plugins/computer-use"
  app_binary="$app/Contents/MacOS/Sentient OS"
  /bin/mkdir -p "$plugin/bin" "$plugin/.codex-plugin" "$plugin/skills/computer-use" \
    "$intel/.agents/plugins" "$(/usr/bin/dirname "$app_binary")"
  /usr/bin/xcrun clang -arch x86_64 "$ROOT/Scripts/Tests/empty.c" -o "$plugin/bin/SentientComputerUseMCP"
  /bin/cp "$plugin/bin/SentientComputerUseMCP" "$plugin/bin/SentientComputerUseService"
  /bin/cp "$ROOT/Scripts/Tests/valid.mcp.json" "$plugin/.mcp.json"
  /bin/cp "$ROOT/NativeComputerUse/Plugin/.codex-plugin/plugin.json" "$plugin/.codex-plugin/plugin.json"
  /bin/cp "$ROOT/NativeComputerUse/Plugin/skills/computer-use/SKILL.md" "$plugin/skills/computer-use/SKILL.md"
  /bin/cp "$ROOT/Scripts/Tests/valid-marketplace.json" "$intel/.agents/plugins/marketplace.json"
  /usr/bin/codesign --force --sign - "$plugin/bin/SentientComputerUseMCP"
  /usr/bin/codesign --force --sign - "$plugin/bin/SentientComputerUseService"
  /bin/cp "$plugin/bin/SentientComputerUseMCP" "$app_binary"
}

test_corrupted_command() {
  app="$TEMP_DIR/Sentient OS.app"
  plugin="$app/Contents/Resources/IntelComputerUse/plugins/computer-use"
  make_valid_app "$app"
  SENTIENT_SKIP_MCP_HANDSHAKE=YES "$ROOT/Scripts/verify-intel-computer-use.sh" "$app"

  /bin/cp "$ROOT/Scripts/Tests/corrupt-command.mcp.json" "$plugin/.mcp.json"
  if SENTIENT_SKIP_MCP_HANDSHAKE=YES "$ROOT/Scripts/verify-intel-computer-use.sh" "$app"; then
    echo "FAIL: verifier accepted a non-exact MCP command" >&2
    exit 1
  fi
  echo "Corrupted MCP command fixture rejected"
}

test_negated_arm64_source() {
  app="$TEMP_DIR/negated/Sentient OS.app"
  source_root="$TEMP_DIR/negated/source"
  make_valid_app "$app"
  /bin/mkdir -p "$source_root/System" \
    "$source_root/Views/Permissions" "$source_root/Views/Settings"
  /usr/bin/printf '%s\n' \
    'let accessibility = "Accessibility is granted to Sentient OS"' \
    'let screen = "Screen Recording is granted to Sentient OS and takes effect after you relaunch Sentient OS"' \
    '#if arch(arm64)' \
    'let owner = "arm"' \
    '#elseif !arch(x86_64)' \
    'let owner = "other"' \
    '#else' \
    '#if !arch(arm64)' \
    'Permissions.grantComputerUseAutomation()' \
    '#endif' \
    '#endif' > "$source_root/NegatedArm64.swift"
  /usr/bin/printf '%s\n' \
    'static func hasComputerUseScreenRecording() -> Bool { CGPreflightScreenCaptureAccess() }' \
    > "$source_root/System/Permissions.swift"
  /usr/bin/printf '%s\n' \
    'StatusLine(title: "Screen Recording (see the screen)")' \
    'let helperScreenRelaunchRequired = true' \
    'Permissions.relaunch()' \
    > "$source_root/Views/Permissions/ComputerUseGateView.swift"
  /usr/bin/printf '%s\n' \
    'StatusLine(title: "Screen Recording (see the screen)")' \
    'let helperScreenRecordingRelaunchRequired = true' \
    'Permissions.relaunch()' \
    > "$source_root/Views/Settings/HealthPane.swift"

  if SENTIENT_INTEL_SOURCE_ROOT="$source_root" SENTIENT_SKIP_MCP_HANDSHAKE=YES \
      "$ROOT/Scripts/verify-intel-computer-use.sh" "$app"; then
    echo "FAIL: verifier ignored an Intel-active call inside #if !arch(arm64)" >&2
    exit 1
  fi
  echo "Negated arm64 Intel branch rejected"
}

test_binary_sky_leak() {
  app="$TEMP_DIR/binary-leak/Sentient OS.app"
  source_file="$TEMP_DIR/binary-leak/sky-leak.c"
  symbol_source="$TEMP_DIR/binary-leak/sky-symbols.swift"
  executable="$app/Contents/MacOS/Sentient OS"
  make_valid_app "$app"
  /bin/mkdir -p "$(/usr/bin/dirname "$executable")"
  /usr/bin/printf '%s\n' \
    'const char *sky = "com.openai.sky.CUAService";' \
    'const char *grant = "grantComputerUseAutomation";' \
    'const char *revoke = "revokeComputerUseAutomation";' \
    'const char *heal = "selfHealComputerUseAutomation";' \
    'int main(void) { return sky[0] + grant[0] + revoke[0] + heal[0] == 0; }' > "$source_file"
  /usr/bin/xcrun clang -arch x86_64 "$source_file" -o "$executable"

  if SENTIENT_SKIP_MCP_HANDSHAKE=YES "$ROOT/Scripts/verify-intel-computer-use.sh" "$app"; then
    echo "FAIL: verifier accepted an Intel app binary containing Sky permission code" >&2
    exit 1
  fi
  echo "Intel binary Sky identifier rejected"

  /usr/bin/printf '%s\n' \
    'enum Permissions {' \
    '  static func grantComputerUseAutomation() {}' \
    '  static func revokeComputerUseAutomation() {}' \
    '  static func selfHealComputerUseAutomation(context: String) {}' \
    '}' \
    '@main struct Fixture {' \
    '  static func main() {' \
    '    Permissions.grantComputerUseAutomation()' \
    '    Permissions.revokeComputerUseAutomation()' \
    '    Permissions.selfHealComputerUseAutomation(context: "fixture")' \
    '  }' \
    '}' > "$symbol_source"
  /usr/bin/xcrun swiftc -parse-as-library -target x86_64-apple-macos15.0 "$symbol_source" -o "$executable"
  if SENTIENT_SKIP_MCP_HANDSHAKE=YES "$ROOT/Scripts/verify-intel-computer-use.sh" "$app"; then
    echo "FAIL: verifier accepted Intel Sky Automation lifecycle symbols" >&2
    exit 1
  fi
  echo "Intel binary Sky Automation symbols rejected"
}

test_marketplace_contract() {
  app="$TEMP_DIR/marketplace/Sentient OS.app"
  intel="$app/Contents/Resources/IntelComputerUse"
  plugin="$intel/plugins/computer-use"
  make_valid_app "$app"
  SENTIENT_SKIP_MCP_HANDSHAKE=YES "$ROOT/Scripts/verify-intel-computer-use.sh" "$app"

  /bin/rm "$intel/.agents/plugins/marketplace.json"
  if SENTIENT_SKIP_MCP_HANDSHAKE=YES "$ROOT/Scripts/verify-intel-computer-use.sh" "$app"; then
    echo "FAIL: verifier accepted a bundle without a marketplace manifest" >&2
    exit 1
  fi
  echo "Missing marketplace manifest rejected"

  make_valid_app "$app"
  /usr/bin/sed -i '' 's/"cwd": "."/"cwd": "\/tmp"/' "$plugin/.mcp.json"
  if SENTIENT_SKIP_MCP_HANDSHAKE=YES "$ROOT/Scripts/verify-intel-computer-use.sh" "$app"; then
    echo "FAIL: verifier accepted a non-local MCP cwd" >&2
    exit 1
  fi
  echo "Invalid MCP cwd rejected"

  make_valid_app "$app"
  /usr/bin/sed -i '' 's/"name": "computer-use"/"name": "wrong-plugin"/' \
    "$plugin/.codex-plugin/plugin.json"
  if SENTIENT_SKIP_MCP_HANDSHAKE=YES "$ROOT/Scripts/verify-intel-computer-use.sh" "$app"; then
    echo "FAIL: verifier accepted invalid plugin metadata" >&2
    exit 1
  fi
  echo "Invalid plugin metadata rejected"

  make_valid_app "$app"
  /usr/bin/printf 'tampered' >> "$plugin/bin/SentientComputerUseService"
  if SENTIENT_SKIP_MCP_HANDSHAKE=YES "$ROOT/Scripts/verify-intel-computer-use.sh" "$app"; then
    echo "FAIL: verifier accepted a binary with an invalid signature" >&2
    exit 1
  fi
  echo "Invalid binary signature rejected"
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
  negated-arm64-source) test_negated_arm64_source ;;
  binary-sky-leak) test_binary_sky_leak ;;
  marketplace-contract) test_marketplace_contract ;;
  stale-cleanup) test_stale_cleanup ;;
  all) test_corrupted_command; test_negated_arm64_source; test_binary_sky_leak; test_marketplace_contract; test_stale_cleanup ;;
  *) echo "usage: $0 [corrupted-command|negated-arm64-source|binary-sky-leak|marketplace-contract|stale-cleanup|all]" >&2; exit 64 ;;
esac
