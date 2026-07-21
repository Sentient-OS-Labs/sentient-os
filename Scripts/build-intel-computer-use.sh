#!/bin/sh

set -eu

: "${SRCROOT:?SRCROOT is required}"
: "${TARGET_BUILD_DIR:?TARGET_BUILD_DIR is required}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?UNLOCALIZED_RESOURCES_FOLDER_PATH is required}"

PACKAGE="$SRCROOT/NativeComputerUse"
STAGE="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/IntelComputerUse"
RELEASE_BIN="$PACKAGE/.build/x86_64-apple-macosx/release"
MCP_NAME="SentientComputerUseMCP"
SERVICE_NAME="SentientComputerUseService"

case "$STAGE" in
  "$TARGET_BUILD_DIR"/*/IntelComputerUse) ;;
  *) echo "error: refusing unexpected staging path: $STAGE" >&2; exit 1 ;;
esac

case " ${ARCHS:-} " in
  *" x86_64 "*) ;;
  *)
    if [ "${BUILD_INTEL_COMPUTER_USE:-NO}" != "YES" ]; then
      if [ -e "$STAGE" ]; then
        echo "Intel Computer Use: removing stale resources for ARCHS=${ARCHS:-unset}"
        /bin/rm -rf "$STAGE"
      else
        echo "Intel Computer Use: skipping for ARCHS=${ARCHS:-unset}"
      fi
      exit 0
    fi
    ;;
esac

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

/bin/rm -rf "$STAGE"
/bin/mkdir -p "$STAGE/plugins/computer-use/bin/SentientComputerUseService.app/Contents/MacOS"
/usr/bin/ditto "$PACKAGE/Marketplace" "$STAGE"
/usr/bin/ditto "$PACKAGE/Plugin" "$STAGE/plugins/computer-use"
/usr/bin/ditto "$RELEASE_BIN/$MCP_NAME" "$STAGE/plugins/computer-use/bin/$MCP_NAME"
/usr/bin/ditto "$RELEASE_BIN/$SERVICE_NAME" "$STAGE/plugins/computer-use/bin/SentientComputerUseService.app/Contents/MacOS/$SERVICE_NAME"
/usr/bin/plutil -create xml1 "$STAGE/plugins/computer-use/bin/SentientComputerUseService.app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string "jesai.Sentient-OS-macOS.ComputerUseService" "$STAGE/plugins/computer-use/bin/SentientComputerUseService.app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleName -string "Sentient Computer Use" "$STAGE/plugins/computer-use/bin/SentientComputerUseService.app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleDisplayName -string "Sentient Computer Use" "$STAGE/plugins/computer-use/bin/SentientComputerUseService.app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string "$SERVICE_NAME" "$STAGE/plugins/computer-use/bin/SentientComputerUseService.app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundlePackageType -string "APPL" "$STAGE/plugins/computer-use/bin/SentientComputerUseService.app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleVersion -string "1" "$STAGE/plugins/computer-use/bin/SentientComputerUseService.app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleShortVersionString -string "1.0.0" "$STAGE/plugins/computer-use/bin/SentientComputerUseService.app/Contents/Info.plist"
/usr/bin/plutil -insert LSBackgroundOnly -bool true "$STAGE/plugins/computer-use/bin/SentientComputerUseService.app/Contents/Info.plist"

SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
SIGN_OPTIONS=""
if [ "${ENABLE_HARDENED_RUNTIME:-NO}" = "YES" ]; then
  SIGN_OPTIONS="--options runtime"
fi
case "$SIGN_IDENTITY" in
  "Developer ID"*) SIGN_OPTIONS="$SIGN_OPTIONS --timestamp" ;;
esac

for executable in "$MCP_NAME"; do
  staged_binary="$STAGE/plugins/computer-use/bin/$executable"
  # shellcheck disable=SC2086 -- SIGN_OPTIONS intentionally expands to separate codesign flags.
  /usr/bin/codesign --force $SIGN_OPTIONS --sign "$SIGN_IDENTITY" "$staged_binary"
  architectures="$(/usr/bin/lipo -archs "$staged_binary")"
  if [ "$architectures" != "x86_64" ]; then
    echo "error: staged $staged_binary must be x86_64-only; found: $architectures" >&2
    exit 1
  fi
done

SERVICE_APP="$STAGE/plugins/computer-use/bin/SentientComputerUseService.app"
SERVICE_BINARY="$SERVICE_APP/Contents/MacOS/$SERVICE_NAME"
# shellcheck disable=SC2086 -- SIGN_OPTIONS intentionally expands to separate codesign flags.
/usr/bin/codesign --force $SIGN_OPTIONS --sign "$SIGN_IDENTITY" "$SERVICE_BINARY"
# Signing the enclosing app makes macOS TCC attribute Screen Recording and Accessibility to a
# selectable app bundle instead of an anonymous command-line executable.
# shellcheck disable=SC2086 -- SIGN_OPTIONS intentionally expands to separate codesign flags.
/usr/bin/codesign --force $SIGN_OPTIONS --sign "$SIGN_IDENTITY" "$SERVICE_APP"

echo "Intel Computer Use: staged signed plugin at $STAGE"
