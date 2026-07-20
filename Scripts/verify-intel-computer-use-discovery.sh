#!/bin/sh

set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 /path/to/Sentient\ OS.app [/path/to/codex]" >&2
  exit 64
fi

APP="$1"
CODEX="${2:-$(command -v codex || true)}"
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
INTEL_ROOT="$APP/Contents/Resources/IntelComputerUse"
PLUGIN_ROOT="$INTEL_ROOT/plugins/computer-use"
TEST_CODEX_HOME="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/sentient-codex-home.XXXXXX")"
TEST_CODEX_HOME="$(CDPATH= cd -- "$TEST_CODEX_HOME" && pwd -P)"
trap 'find "$TEST_CODEX_HOME" -depth -delete' EXIT HUP INT TERM

if [ -z "$CODEX" ] || [ ! -x "$CODEX" ]; then
  echo "error: real Codex CLI executable not found" >&2
  exit 1
fi

"$ROOT/Scripts/verify-intel-computer-use.sh" "$APP"

MARKETPLACE="$TEST_CODEX_HOME/.tmp/marketplaces/sentient"
CACHE="$TEST_CODEX_HOME/plugins/cache/sentient/computer-use/1.0.0"
/bin/mkdir -p "$(/usr/bin/dirname "$MARKETPLACE")" "$(/usr/bin/dirname "$CACHE")"
/usr/bin/ditto "$INTEL_ROOT" "$MARKETPLACE"
/usr/bin/ditto "$PLUGIN_ROOT" "$CACHE"

CONFIG="$TEST_CODEX_HOME/config.toml"
/usr/bin/printf '%s\n' \
  '[marketplaces.sentient]' \
  'source_type = "local"' \
  "source = \"$MARKETPLACE\"" \
  '' \
  '[plugins."computer-use@sentient"]' \
  'enabled = true' \
  '' \
  '[plugins."computer-use@openai-bundled"]' \
  'enabled = false' \
  > "$CONFIG"

MARKETPLACES="$TEST_CODEX_HOME/marketplaces.json"
PLUGINS="$TEST_CODEX_HOME/plugins.json"
CODEX_HOME="$TEST_CODEX_HOME" "$CODEX" plugin marketplace list --json > "$MARKETPLACES"
CODEX_HOME="$TEST_CODEX_HOME" "$CODEX" plugin list --marketplace sentient --available --json > "$PLUGINS"

JQ="$(command -v jq || true)"
if [ -z "$JQ" ]; then
  echo "error: jq is required to verify Codex CLI discovery" >&2
  exit 1
fi
if ! "$JQ" -e --arg root "$MARKETPLACE" '
    any(.marketplaces[]; .name == "sentient" and .root == $root
      and .marketplaceSource.sourceType == "local"
      and .marketplaceSource.source == $root)
  ' "$MARKETPLACES" >/dev/null; then
  echo "error: real Codex CLI did not discover the Sentient marketplace" >&2
  exit 1
fi
if ! "$JQ" -e '
    any(.installed[]; .pluginId == "computer-use@sentient"
      and .marketplaceName == "sentient"
      and .version == "1.0.0"
      and .installed == true
      and .enabled == true)
  ' "$PLUGINS" >/dev/null; then
  echo "error: real Codex CLI did not discover the installed Sentient plugin" >&2
  "$JQ" . "$PLUGINS" >&2
  exit 1
fi

echo "Real Codex CLI discovered computer-use@sentient 1.0.0 from the local Sentient marketplace"
