#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="ClaudePromptTranslator"
BUNDLE_ID="local.codex.ClaudePromptTranslator"
SCHEME="ClaudePromptTranslator"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/ClaudePromptTranslator.xcodeproj"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/ClaudePromptTranslatorXcodeDerivedData}"
APP_BUNDLE="$DERIVED_DATA_PATH/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cd "$ROOT_DIR"

if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

stop_existing() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

build_bundle() {
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    build
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

verify_process() {
  sleep 1
  pgrep -x "$APP_NAME" >/dev/null
}

stop_existing
build_bundle
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" >/dev/null

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    verify_process
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
