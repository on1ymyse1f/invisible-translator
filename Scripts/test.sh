#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH_PATH="$(mktemp -d "${TMPDIR:-/tmp}/ClaudePromptTranslator-tests.XXXXXX")"

cleanup() {
  if [[ -n "${SCRATCH_PATH}" && -d "${SCRATCH_PATH}" \
        && "$(basename "${SCRATCH_PATH}")" == ClaudePromptTranslator-tests.* ]]; then
    rm -rf -- "${SCRATCH_PATH}"
  fi
}
trap cleanup EXIT

echo "Running isolated tests in ${SCRATCH_PATH}"
swift test \
  --package-path "${ROOT_DIR}" \
  --scratch-path "${SCRATCH_PATH}" \
  --enable-code-coverage \
  "$@"
