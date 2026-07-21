#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/sentient-cu-config.XXXXXX")"
trap 'find "$TEMP_DIR" -depth -delete' EXIT HUP INT TERM

/usr/bin/xcrun swiftc -parse-as-library \
  "$ROOT/Sentient OS macOS/Cloud/ComputerUsePluginConfig.swift" \
  "$ROOT/Sentient OS macOS/Cloud/ComputerUseSkyInstallCoordinator.swift" \
  "$ROOT/Scripts/Tests/ComputerUsePluginConfigTests.swift" \
  -o "$TEMP_DIR/ComputerUsePluginConfigTests"
"$TEMP_DIR/ComputerUsePluginConfigTests"
