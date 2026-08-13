#!/usr/bin/env bash
set -euo pipefail

# SwiftPM writes all incremental products for interactive development outside
# the checkout. Release packaging deliberately uses its own temporary scratch
# directory instead; see package-app.sh.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_ROOT="${CPT_BUILD_CACHE_DIR:-${HOME}/Library/Caches/ClaudePromptTranslator/Build}"
CACHE_PARENT="${HOME}/Library/Caches/ClaudePromptTranslator"
SCRATCH_DIR="${CACHE_ROOT}/default"
LOCK_FILE="${CACHE_ROOT}/.development-build.lock"

case "${CACHE_ROOT}" in
  "${CACHE_PARENT}"/*) ;;
  *) echo "Refusing a build cache outside the app-owned cache directory." >&2; exit 2 ;;
esac
[[ "${CACHE_ROOT}" != "${CACHE_PARENT}" && "${CACHE_ROOT}" != "/" && "${CACHE_ROOT}" != "${HOME}" ]] \
  || { echo "Refusing a broad build-cache location." >&2; exit 2; }
[[ ! -L "${CACHE_PARENT}" && ! -L "${CACHE_ROOT}" ]] \
  || { echo "Refusing a symbolic-link build-cache root." >&2; exit 2; }

mkdir -p "${CACHE_ROOT}"
if ! /usr/bin/shlock -f "${LOCK_FILE}" -p $$; then
  echo "Another development build is already using this app-owned cache." >&2
  exit 3
fi
cleanup_lock() {
  /bin/rm -f -- "${LOCK_FILE}"
}
trap cleanup_lock EXIT

mkdir -p "${SCRATCH_DIR}"
"${ROOT_DIR}/Scripts/prune-build-cache.sh" --quiet

echo "Building with SwiftPM cache: ${SCRATCH_DIR}"
swift build \
  --package-path "${ROOT_DIR}" \
  --scratch-path "${SCRATCH_DIR}" \
  "$@"
/usr/bin/touch "${SCRATCH_DIR}"
