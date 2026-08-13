#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: audit-artifact.sh [--tier core|full] APP_PATH [ZIP_PATH]

Checks package size and rejects embedded model weights, dSYMs, test hosts and
screenshots. `core` is the 0.8 gate (3.2 MiB app / 2.2 MiB ZIP); `full` is the
1.0 base-app gate (24 MiB app / 12 MiB ZIP). Models are never permitted in
either base artifact.
USAGE
}

TIER="core"
if [[ "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ "${1:-}" == "--tier" ]]; then
  TIER="${2:-}"
  shift 2
fi
if [[ "${TIER}" != "core" && "${TIER}" != "full" ]]; then
  usage >&2
  exit 2
fi
if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage >&2
  exit 2
fi

APP_PATH="$1"
ZIP_PATH="${2:-}"
if [[ ! -d "${APP_PATH}" ]]; then
  echo "Artifact audit failed: app bundle is missing: ${APP_PATH}" >&2
  exit 1
fi
if [[ -n "${ZIP_PATH}" && ! -f "${ZIP_PATH}" ]]; then
  echo "Artifact audit failed: ZIP is missing: ${ZIP_PATH}" >&2
  exit 1
fi

case "${TIER}" in
  core)
    APP_LIMIT_KIB=3276
    ZIP_LIMIT_KIB=2252
    ;;
  full)
    APP_LIMIT_KIB=24576
    ZIP_LIMIT_KIB=12288
    ;;
esac

app_kib="$(/usr/bin/du -sk "${APP_PATH}" | /usr/bin/awk '{print $1}')"
if (( app_kib > APP_LIMIT_KIB )); then
  echo "Artifact audit failed: ${TIER} app is ${app_kib} KiB; limit is ${APP_LIMIT_KIB} KiB." >&2
  exit 1
fi
if [[ -n "${ZIP_PATH}" ]]; then
  zip_kib="$(/usr/bin/du -sk "${ZIP_PATH}" | /usr/bin/awk '{print $1}')"
  if (( zip_kib > ZIP_LIMIT_KIB )); then
    echo "Artifact audit failed: ${TIER} ZIP is ${zip_kib} KiB; limit is ${ZIP_LIMIT_KIB} KiB." >&2
    exit 1
  fi
fi

forbidden_pattern='.*\.(mlmodel|mlpackage|onnx|gguf|safetensors|ckpt|tflite|pt|pth|dSYM)$|(^|/)(Models|ModelWeights)/|\.mlmodelc(/|$)|(^|/)[^/]*(Tests|UITests)\.xctest(/|$)|(^|/)(xctest|TestHost)($|/)|(^|/)[^/]*(screenshot|screen[-_]?shot)[^/]*\.(png|jpe?g|heic)$'
forbidden="$({
  /usr/bin/find "${APP_PATH}" -print | /usr/bin/sed "s#^${APP_PATH}/##" | /usr/bin/grep -E -i "${forbidden_pattern}" || true
  if [[ -n "${ZIP_PATH}" ]]; then
    /usr/bin/unzip -Z1 "${ZIP_PATH}" | /usr/bin/grep -E -i "${forbidden_pattern}" || true
  fi
} | /usr/bin/sort -u)"
if [[ -n "${forbidden}" ]]; then
  echo "Artifact audit failed: base artifact contains prohibited payload:" >&2
  echo "${forbidden}" >&2
  exit 1
fi

if [[ -n "${ZIP_PATH}" ]]; then
  if /usr/bin/unzip -Z1 "${ZIP_PATH}" | /usr/bin/grep -Eq '^__MACOSX/'; then
    echo "Artifact audit failed: ZIP contains Finder metadata (__MACOSX)." >&2
    exit 1
  fi
fi

echo "Artifact audit passed (${TIER}): app=${app_kib} KiB${ZIP_PATH:+, zip=$(du -sk "${ZIP_PATH}" | awk '{print $1}') KiB}."
