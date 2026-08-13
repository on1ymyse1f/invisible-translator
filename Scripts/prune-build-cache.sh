#!/usr/bin/env bash
set -euo pipefail

# This only ever manages the cache directory owned by this application. It is
# intentionally not called by release packaging, so a release cannot evict a
# developer's incremental build while it is being created.
CACHE_ROOT="${CPT_BUILD_CACHE_DIR:-${HOME}/Library/Caches/ClaudePromptTranslator/Build}"
CACHE_PARENT="${HOME}/Library/Caches/ClaudePromptTranslator"
LOCK_NAME=".development-build.lock"
MAX_BYTES=$((512 * 1024 * 1024))
MAX_AGE_DAYS=14
QUIET=0

if [[ "${1:-}" == "--quiet" ]]; then
  QUIET=1
  shift
fi
if [[ $# -ne 0 ]]; then
  echo "Usage: $0 [--quiet]" >&2
  exit 2
fi

case "${CACHE_ROOT}" in
  "${CACHE_PARENT}"/*) ;;
  *)
    echo "Refusing to prune outside the app-owned cache directory." >&2
    exit 2
    ;;
esac
if [[ "${CACHE_ROOT}" == "${CACHE_PARENT}" || "${CACHE_ROOT}" == "/" || "${CACHE_ROOT}" == "${HOME}" ]]; then
  echo "Refusing to prune a broad cache location." >&2
  exit 2
fi
if [[ -L "${CACHE_PARENT}" || -L "${CACHE_ROOT}" ]]; then
  echo "Refusing to prune a cache path containing a symbolic-link root." >&2
  exit 2
fi
if [[ ! -d "${CACHE_ROOT}" ]]; then
  exit 0
fi

# Canonicalization catches a path such as Build/../../Documents even when it
# was supplied through the development-only override.
CANONICAL_PARENT="$(cd "${CACHE_PARENT}" && pwd -P)"
CANONICAL_ROOT="$(cd "${CACHE_ROOT}" && pwd -P)"
case "${CANONICAL_ROOT}" in
  "${CANONICAL_PARENT}"/*) ;;
  *)
    echo "Refusing to prune a cache path that escapes its owned directory." >&2
    exit 2
    ;;
esac
CACHE_ROOT="${CANONICAL_ROOT}"

log() {
  if [[ "${QUIET}" == "0" ]]; then
    echo "$*"
  fi
}

# First remove only stale leaf entries. find's xargs input is NUL-delimited so
# spaces and non-ASCII project names remain safe. The depth guard protects the
# cache root itself even if its timestamp is old.
while IFS= read -r -d '' candidate; do
  [[ "${candidate}" == "${CACHE_ROOT}" ]] && continue
  [[ "$(basename "${candidate}")" == "${LOCK_NAME}" ]] && continue
  [[ -L "${candidate}" ]] && continue
  case "${candidate}" in
    "${CACHE_ROOT}"/*) ;;
    *) echo "Refusing an out-of-root cache entry." >&2; exit 2 ;;
  esac
  /bin/rm -rf -- "${candidate}"
  log "Pruned stale build cache entry: ${candidate}"
done < <(/usr/bin/find "${CACHE_ROOT}" -mindepth 1 -maxdepth 1 -mtime "+${MAX_AGE_DAYS}" -print0)

cache_bytes() {
  # du -sk is available on every supported macOS version and avoids loading a
  # directory tree into the shell.
  local kib
  kib="$(/usr/bin/du -sk "${CACHE_ROOT}" | /usr/bin/awk '{print $1}')"
  echo $((kib * 1024))
}

current_bytes="$(cache_bytes)"
if (( current_bytes <= MAX_BYTES )); then
  log "Build cache is within budget: ${current_bytes} bytes."
  exit 0
fi

# Enforce the byte ceiling by evicting oldest top-level entries, which are
# complete SwiftPM scratch subtrees. Never delete a child selectively: that
# could corrupt a currently reusable build product.
while (( current_bytes > MAX_BYTES )); do
  oldest="$(/usr/bin/find "${CACHE_ROOT}" -mindepth 1 -maxdepth 1 ! -name "${LOCK_NAME}" -print0 \
    | /usr/bin/xargs -0 -n1 stat -f '%m %N' \
    | /usr/bin/sort -n \
    | /usr/bin/head -n 1 \
    | /usr/bin/sed 's/^[0-9][0-9]* //')"
  if [[ -z "${oldest}" || ! -e "${oldest}" || -L "${oldest}" ]]; then
    echo "Unable to safely identify an evictable build-cache entry." >&2
    exit 1
  fi
  case "${oldest}" in
    "${CACHE_ROOT}"/*) ;;
    *) echo "Refusing an out-of-root cache entry." >&2; exit 2 ;;
  esac
  /bin/rm -rf -- "${oldest}"
  log "Evicted build cache entry to meet 512 MiB cap: ${oldest}"
  current_bytes="$(cache_bytes)"
done

log "Build cache pruned to ${current_bytes} bytes."
