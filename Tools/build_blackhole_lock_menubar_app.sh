#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="BlackHoleLockMenuBar"
SRC_DIR="$SCRIPT_DIR/BlackHoleLockMenuBar"
BUILD_DIR="$SCRIPT_DIR/build-menubar"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
BIN_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"
ICON_SRC="$SCRIPT_DIR/../BlackHole/BlackHole.icns"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "error: swiftc not found in PATH" >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$BIN_DIR" "$RES_DIR"

swiftc -O "$SRC_DIR/main.swift" -framework AppKit -framework CoreAudio -o "$BIN_DIR/$APP_NAME"
cp "$SRC_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
if [[ -f "$ICON_SRC" ]]; then
  cp "$ICON_SRC" "$RES_DIR/BlackHole.icns"
fi
chmod +x "$BIN_DIR/$APP_NAME"

echo "Built app: $APP_DIR"
echo "Run with: open \"$APP_DIR\""
