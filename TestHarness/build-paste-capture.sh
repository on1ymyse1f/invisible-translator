#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/TestHarness/dist/PasteCapture.app"
BIN_DIR="$APP_DIR/Contents/MacOS"
BIN="$BIN_DIR/PasteCapture"

if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

rm -rf "$APP_DIR"
mkdir -p "$BIN_DIR"

xcrun swiftc "$ROOT_DIR/TestHarness/PasteCapture.swift" -o "$BIN" -framework AppKit
cp "$ROOT_DIR/TestHarness/PasteCapture-Info.plist" "$APP_DIR/Contents/Info.plist"
xattr -cr "$APP_DIR"
find "$APP_DIR" -exec xattr -d com.apple.FinderInfo {} \; 2>/dev/null || true
codesign --force --sign - "$APP_DIR" >/dev/null

echo "$APP_DIR"
