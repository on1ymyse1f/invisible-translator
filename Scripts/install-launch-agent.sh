#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${APP_PATH:-$HOME/Applications/ClaudePromptTranslator.app}"
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/ClaudePromptTranslator"
PLIST_PATH="$HOME/Library/LaunchAgents/local.codex.ClaudePromptTranslator.plist"
LABEL="local.codex.ClaudePromptTranslator"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  echo "Run Scripts/package-app.sh first, or pass APP_PATH=/path/to/ClaudePromptTranslator.app." >&2
  exit 1
fi

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
  echo "Executable not found: $EXECUTABLE_PATH" >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"

cat >"$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$EXECUTABLE_PATH</string>
    <string>--silent</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/claude_prompt_translator_launch_agent.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/claude_prompt_translator_launch_agent.err.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
pkill -x "$(basename "$EXECUTABLE_PATH")" >/dev/null 2>&1 || true
sleep 0.3
if ! launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" 2>/tmp/claude_prompt_translator_bootstrap.err; then
  if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    :
  else
    cat /tmp/claude_prompt_translator_bootstrap.err >&2
    exit 1
  fi
fi
launchctl kickstart -k "gui/$(id -u)/$LABEL"

echo "Installed and started $LABEL"
echo "Plist: $PLIST_PATH"
echo "App: $APP_PATH"
