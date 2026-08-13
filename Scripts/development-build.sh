#!/usr/bin/env bash
set -euo pipefail

# SwiftPM writes all incremental products for interactive development outside
# the checkout. Release packaging deliberately uses its own temporary scratch
# directory instead; see package-app.sh.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_ROOT="${CPT_BUILD_CACHE_DIR:-${HOME}/Library/Caches/ClaudePromptTranslator/Build}"
CACHE_PARENT="${HOME}/Library/Caches/ClaudePromptTranslator"

case "${CACHE_ROOT}" in
  "${CACHE_PARENT}"/*) ;;
  *) echo "Refusing a build cache outside the app-owned cache directory." >&2; exit 2 ;;
esac
[[ "${CACHE_ROOT}" != "${CACHE_PARENT}" && "${CACHE_ROOT}" != "/" && "${CACHE_ROOT}" != "${HOME}" ]] \
  || { echo "Refusing a broad build-cache location." >&2; exit 2; }
case "/${CACHE_ROOT#/}/" in
  *"/../"*|*"/./"*|*"//"*)
    echo "Refusing a non-canonical build-cache path." >&2
    exit 2
    ;;
esac

# Create each app-owned component without ever traversing a symlink supplied
# through CPT_BUILD_CACHE_DIR. Checking only the final path is too late: a
# nested symlink could otherwise redirect mkdir/SwiftPM outside this cache.
mkdir -p "${CACHE_PARENT}"
[[ ! -L "${CACHE_PARENT}" ]] \
  || { echo "Refusing a symbolic-link build-cache parent." >&2; exit 2; }
RELATIVE_CACHE_ROOT="${CACHE_ROOT#"${CACHE_PARENT}"/}"
SAFE_CACHE_ROOT="${CACHE_PARENT}"
IFS='/' read -r -a CACHE_COMPONENTS <<<"${RELATIVE_CACHE_ROOT}"
for CACHE_COMPONENT in "${CACHE_COMPONENTS[@]}"; do
  [[ -n "${CACHE_COMPONENT}" && "${CACHE_COMPONENT}" != "." && "${CACHE_COMPONENT}" != ".." ]] \
    || { echo "Refusing an unsafe build-cache component." >&2; exit 2; }
  SAFE_CACHE_ROOT="${SAFE_CACHE_ROOT}/${CACHE_COMPONENT}"
  if [[ -L "${SAFE_CACHE_ROOT}" ]]; then
    echo "Refusing a symbolic link inside the build-cache path." >&2
    exit 2
  fi
  if [[ -e "${SAFE_CACHE_ROOT}" && ! -d "${SAFE_CACHE_ROOT}" ]]; then
    echo "Refusing a non-directory build-cache component." >&2
    exit 2
  fi
  [[ -d "${SAFE_CACHE_ROOT}" ]] || mkdir "${SAFE_CACHE_ROOT}"
done

CANONICAL_PARENT="$(cd "${CACHE_PARENT}" && pwd -P)"
CANONICAL_ROOT="$(cd "${SAFE_CACHE_ROOT}" && pwd -P)"
case "${CANONICAL_ROOT}" in
  "${CANONICAL_PARENT}"/*) ;;
  *) echo "Refusing a build cache that escapes its owned directory." >&2; exit 2 ;;
esac
CACHE_ROOT="${CANONICAL_ROOT}"
SCRATCH_DIR="${CACHE_ROOT}/default"
LOCK_FILE="${CACHE_ROOT}/.development-build.lock"

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
