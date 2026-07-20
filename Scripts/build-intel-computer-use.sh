#!/bin/sh

set -eu

case " ${ARCHS:-} " in
  *" x86_64 "*) ;;
  *)
    if [ "${BUILD_INTEL_COMPUTER_USE:-NO}" != "YES" ]; then
      echo "Intel Computer Use: skipping for ARCHS=${ARCHS:-unset}"
      exit 0
    fi
    ;;
esac

: "${SRCROOT:?SRCROOT is required}"
: "${TARGET_BUILD_DIR:?TARGET_BUILD_DIR is required}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?UNLOCALIZED_RESOURCES_FOLDER_PATH is required}"

PACKAGE="$SRCROOT/NativeComputerUse"
STAGE="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/IntelComputerUse"
RELEASE_BIN="$PACKAGE/.build/x86_64-apple-macosx/release"
MCP_NAME="SentientComputerUseMCP"
SERVICE_NAME="SentientComputerUseService"

echo "Intel Computer Use: building x86_64 release executables"
/usr/bin/xcrun swift build --package-path "$PACKAGE" -c release --arch x86_64 --product "$MCP_NAME"
/usr/bin/xcrun swift build --package-path "$PACKAGE" -c release --arch x86_64 --product "$SERVICE_NAME"

for executable in "$MCP_NAME" "$SERVICE_NAME"; do
  source_binary="$RELEASE_BIN/$executable"
  architectures="$(/usr/bin/lipo -archs "$source_binary")"
  if [ "$architectures" != "x86_64" ]; then
    echo "error: $source_binary must be x86_64-only; found: $architectures" >&2
    exit 1
  fi
done

case "$STAGE" in
  "$TARGET_BUILD_DIR"/*/IntelComputerUse) ;;
  *) echo "error: refusing to replace unexpected staging path: $STAGE" >&2; exit 1 ;;
esac
/bin/rm -rf "$STAGE"
/bin/mkdir -p "$STAGE/bin"
/usr/bin/ditto "$PACKAGE/Plugin" "$STAGE"
/usr/bin/ditto "$RELEASE_BIN/$MCP_NAME" "$STAGE/bin/$MCP_NAME"
/usr/bin/ditto "$RELEASE_BIN/$SERVICE_NAME" "$STAGE/bin/$SERVICE_NAME"

SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
SIGN_OPTIONS=""
if [ "${ENABLE_HARDENED_RUNTIME:-NO}" = "YES" ]; then
  SIGN_OPTIONS="--options runtime"
fi
case "$SIGN_IDENTITY" in
  "Developer ID"*) SIGN_OPTIONS="$SIGN_OPTIONS --timestamp" ;;
esac

for executable in "$MCP_NAME" "$SERVICE_NAME"; do
  staged_binary="$STAGE/bin/$executable"
  # shellcheck disable=SC2086 -- SIGN_OPTIONS intentionally expands to separate codesign flags.
  /usr/bin/codesign --force $SIGN_OPTIONS --sign "$SIGN_IDENTITY" "$staged_binary"
  architectures="$(/usr/bin/lipo -archs "$staged_binary")"
  if [ "$architectures" != "x86_64" ]; then
    echo "error: staged $staged_binary must be x86_64-only; found: $architectures" >&2
    exit 1
  fi
done

echo "Intel Computer Use: staged signed plugin at $STAGE"
