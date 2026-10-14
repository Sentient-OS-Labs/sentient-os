#!/bin/bash
# Offline regressions against the production SiYuan reader and connector. No user data or model.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sentient-siyuan-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$REPO_ROOT"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$TEST_DIR/modules" \
    Scripts/test_siyuan.swift \
    "Sentient OS macOS/Sources/SiYuanNote.swift" \
    "Sentient OS macOS/Sources/SiYuanSource.swift" \
    "Sentient OS macOS/Sources/DataSource.swift" \
    "Sentient OS macOS/Ingestion/ItemKey.swift" \
    "Sentient OS macOS/Ingestion/Connector.swift" \
    "Sentient OS macOS/Ingestion/Connectors/SiYuanConnector.swift" \
    -o "$TEST_DIR/checks"
"$TEST_DIR/checks"
