#!/usr/bin/env bash
set -euo pipefail

PUBLIC_RELEASE=0
if [[ "${1:-}" == "--public" ]]; then
  PUBLIC_RELEASE=1
  shift
fi

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 [--public] /path/to/ClaudePromptTranslator.app" >&2
  exit 2
fi

APP_PATH="$1"
APP_NAME="ClaudePromptTranslator"
APP_BINARY="${APP_PATH}/Contents/MacOS/${APP_NAME}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED_INFO_PLIST="${ROOT_DIR}/Packaging/Info.plist"
APP_INFO_PLIST="${APP_PATH}/Contents/Info.plist"

if [[ ! -d "${APP_PATH}" || ! -x "${APP_BINARY}" ]]; then
  echo "Release app or executable not found: ${APP_PATH}" >&2
  exit 1
fi

if [[ ! -f "${APP_INFO_PLIST}" || ! -f "${EXPECTED_INFO_PLIST}" ]]; then
  echo "Release verification failed: Info.plist manifest is missing." >&2
  exit 1
fi

for PLIST_KEY in \
  CFBundleIdentifier \
  CFBundleExecutable \
  CFBundlePackageType \
  CFBundleShortVersionString \
  CFBundleVersion \
  LSMinimumSystemVersion; do
  EXPECTED_VALUE="$(/usr/libexec/PlistBuddy -c "Print :${PLIST_KEY}" "${EXPECTED_INFO_PLIST}")"
  ACTUAL_VALUE="$(/usr/libexec/PlistBuddy -c "Print :${PLIST_KEY}" "${APP_INFO_PLIST}")"
  if [[ "${ACTUAL_VALUE}" != "${EXPECTED_VALUE}" ]]; then
    echo "Release verification failed: ${PLIST_KEY} is ${ACTUAL_VALUE}, expected ${EXPECTED_VALUE}." >&2
    exit 1
  fi
done

if /usr/bin/find "${APP_PATH}/Contents" -type l -print -quit | /usr/bin/grep -q .; then
  echo "Release verification failed: symbolic links are not allowed in this single-binary bundle." >&2
  exit 1
fi

while IFS= read -r -d '' EXECUTABLE_CANDIDATE; do
  if [[ "${EXECUTABLE_CANDIDATE}" != "${APP_BINARY}" ]]; then
    echo "Release verification failed: unexpected executable file: ${EXECUTABLE_CANDIDATE}" >&2
    exit 1
  fi
done < <(/usr/bin/find "${APP_PATH}/Contents" -type f -perm -111 -print0)

codesign --verify --deep --strict --verbose=2 "${APP_PATH}" >/dev/null

# This app intentionally ships as one native executable with no helper,
# framework, plug-in, or embedded runtime. A new Mach-O must be explicitly
# reviewed before the release allowlist is expanded.
MACHO_COUNT=0
while IFS= read -r -d '' CANDIDATE_PATH; do
  if /usr/bin/file -b "${CANDIDATE_PATH}" | /usr/bin/grep -Fq 'Mach-O'; then
    MACHO_COUNT=$((MACHO_COUNT + 1))
    if [[ "${CANDIDATE_PATH}" != "${APP_BINARY}" ]]; then
      echo "Release verification failed: unexpected embedded executable: ${CANDIDATE_PATH}" >&2
      exit 1
    fi
  fi
done < <(/usr/bin/find "${APP_PATH}/Contents" -type f -print0)

if [[ "${MACHO_COUNT}" -ne 1 ]]; then
  echo "Release verification failed: expected exactly one Mach-O executable, found ${MACHO_COUNT}." >&2
  exit 1
fi

SIGNING_DETAILS="$(codesign -d --verbose=4 "${APP_PATH}" 2>&1)"
if ! /usr/bin/grep -Eq 'flags=.*\(runtime\)' <<<"${SIGNING_DETAILS}"; then
  echo "Release verification failed: hardened runtime is not enabled." >&2
  exit 1
fi

if [[ "${PUBLIC_RELEASE}" == "1" ]]; then
  if ! /usr/bin/grep -Fq 'Authority=Developer ID Application:' <<<"${SIGNING_DETAILS}"; then
    echo "Public Release verification failed: Developer ID Application signature required." >&2
    exit 1
  fi
  if ! /usr/bin/grep -Eq '^Timestamp=.+' <<<"${SIGNING_DETAILS}"; then
    echo "Public Release verification failed: secure signing timestamp required." >&2
    exit 1
  fi
fi

for FORBIDDEN_MARKER in \
  '--self-test-paste' \
  '--self-test-set-input' \
  '--self-test-inspect-input' \
  '--self-test-selection' \
  '--self-test-inline' \
  '--self-test-response' \
  'CPTDebugSelection' \
  'CPT_DEBUG_SELECTION' \
  'CPT_DEBUG_SELECTION_PID' \
  'CPT_DEBUG_DELIVERY' \
  'translate.googleapis.com' \
  'GoogleTranslateClient' \
  'URLSession' \
  'NSURLSession' \
  'NWConnection' \
  'WebSocket' \
  'CFHTTP' \
  'libcurl'; do
  if /usr/bin/strings "${APP_BINARY}" | /usr/bin/grep -Fq -- "${FORBIDDEN_MARKER}"; then
    echo "Release verification failed: forbidden marker present: ${FORBIDDEN_MARKER}" >&2
    exit 1
  fi
done

if otool -L "${APP_BINARY}" | /usr/bin/grep -Eq \
  'CFNetwork\.framework|Network\.framework|WebKit\.framework|libcurl'; then
  echo "Release verification failed: a network-capable runtime is linked." >&2
  exit 1
fi

if nm -u "${APP_BINARY}" | /usr/bin/grep -Eq \
  '(_nw_|_CFHTTP|_CFNetwork|_socket$|_connect$|_getaddrinfo$|_send(to)?$|_recv(from)?$)'; then
  echo "Release verification failed: a low-level network symbol is imported." >&2
  exit 1
fi

ENTITLEMENTS="$(codesign -d --entitlements - "${APP_PATH}" 2>/dev/null || true)"
if /usr/bin/grep -Eq \
  'com\.apple\.security\.network\.(client|server)' <<<"${ENTITLEMENTS}"; then
  echo "Release verification failed: a network entitlement is enabled." >&2
  exit 1
fi

if [[ "${PUBLIC_RELEASE}" == "1" ]]; then
  echo "Verified public-signing prerequisites for ${APP_PATH}"
else
  echo "Verified privacy-safe local Release app ${APP_PATH}"
fi
