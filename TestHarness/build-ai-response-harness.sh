#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_TARGET_APP="${ROOT_DIR}/TestHarness/dist/ChatGPTSyntheticHarness.app"
TARGET_APP="${TARGET_APP:-${DEFAULT_TARGET_APP}}"
TEMP_ROOT="${TMPDIR:-/tmp}"
if [[ "${TARGET_APP}" != "${DEFAULT_TARGET_APP}" \
      && "${TARGET_APP}" != "${TEMP_ROOT}"/*/ChatGPTSyntheticHarness.app ]]; then
  echo "Refusing unsafe harness target: ${TARGET_APP}" >&2
  exit 1
fi
SCRATCH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cpt-response-harness.XXXXXX")"
STAGED_APP="${SCRATCH_DIR}/ChatGPTSyntheticHarness.app"
STAGED_BINARY="${STAGED_APP}/Contents/MacOS/ChatGPTSyntheticHarness"
BACKUP_APP="${SCRATCH_DIR}/previous.app"

cleanup() {
  rm -rf "${SCRATCH_DIR}"
}
trap cleanup EXIT

mkdir -p "$(dirname "${STAGED_BINARY}")"
xcrun swiftc \
  "${ROOT_DIR}/TestHarness/AIResponseHarness.swift" \
  -o "${STAGED_BINARY}" \
  -framework AppKit
install -m 0644 \
  "${ROOT_DIR}/TestHarness/AIResponseHarness-Info.plist" \
  "${STAGED_APP}/Contents/Info.plist"
xattr -cr "${STAGED_APP}"
codesign --force --sign - "${STAGED_APP}" >/dev/null

mkdir -p "$(dirname "${TARGET_APP}")"
if [[ -e "${TARGET_APP}" ]]; then
  mv "${TARGET_APP}" "${BACKUP_APP}"
fi

if ! mv "${STAGED_APP}" "${TARGET_APP}"; then
  if [[ -e "${BACKUP_APP}" ]]; then
    mv "${BACKUP_APP}" "${TARGET_APP}"
  fi
  exit 1
fi

# File Provider can attach Finder metadata as soon as the bundle enters the
# workspace. Clear metadata only on this generated artifact. The staged bundle
# was already signed in /tmp; re-signing after the move is both unnecessary and
# vulnerable to metadata being reattached between cleanup and codesign.
xattr -cr "${TARGET_APP}"
find "${TARGET_APP}" -exec xattr -d com.apple.FinderInfo {} \; 2>/dev/null || true
find "${TARGET_APP}" -exec xattr -d com.apple.ResourceFork {} \; 2>/dev/null || true

if codesign --verify --deep --strict "${TARGET_APP}"; then
  rm -rf "${BACKUP_APP}"
else
  mv "${TARGET_APP}" "${SCRATCH_DIR}/failed.app" 2>/dev/null || true
  if [[ -e "${BACKUP_APP}" ]]; then
    mv "${BACKUP_APP}" "${TARGET_APP}"
  fi
  exit 1
fi

echo "${TARGET_APP}"
