#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${APP_PATH:-$HOME/Applications/ClaudePromptTranslator.app}"

if ! pgrep -x ClaudePromptTranslator >/dev/null 2>&1; then
  /usr/bin/open -gj "$APP_PATH" --args --silent
  sleep 0.6
fi

/usr/bin/open "claude-prompt-translator://show"
