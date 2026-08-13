#!/usr/bin/env bash
set -euo pipefail

PUBLIC_RELEASE=0
REQUIRE_GATEKEEPER=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --public)
      PUBLIC_RELEASE=1
      shift
      ;;
    --require-gatekeeper)
      REQUIRE_GATEKEEPER=1
      shift
      ;;
    --help)
      echo "Usage: $0 [--public] [--require-gatekeeper] /path/to/ClaudePromptTranslator.app"
      exit 0
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 [--public] [--require-gatekeeper] /path/to/ClaudePromptTranslator.app" >&2
  exit 2
fi

APP_PATH="$1"
APP_NAME="ClaudePromptTranslator"
APP_BINARY="${APP_PATH}/Contents/MacOS/${APP_NAME}"
NATIVE_HOST_BINARY="${APP_PATH}/Contents/MacOS/ClaudePromptTranslatorNativeHost"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED_INFO_PLIST="${ROOT_DIR}/Packaging/Info.plist"
APP_INFO_PLIST="${APP_PATH}/Contents/Info.plist"

if [[ ! -d "${APP_PATH}" || ! -x "${APP_BINARY}" || ! -x "${NATIVE_HOST_BINARY}" ]]; then
  echo "Release app or executable not found: ${APP_PATH}" >&2
  exit 1
fi

# Distribution is Apple Silicon only. Exact equality also rejects a universal
# binary that happens to contain arm64 alongside any unsupported architecture.
APP_BINARY_ARCHITECTURES="$(/usr/bin/lipo -archs "${APP_BINARY}" 2>/dev/null || true)"
if [[ "${APP_BINARY_ARCHITECTURES}" != "arm64" ]]; then
  echo "Release verification failed: main executable must be arm64-only; found ${APP_BINARY_ARCHITECTURES:-<unknown>}." >&2
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
  LSMinimumSystemVersion \
  NSSpeechRecognitionUsageDescription; do
  EXPECTED_VALUE="$(/usr/libexec/PlistBuddy -c "Print :${PLIST_KEY}" "${EXPECTED_INFO_PLIST}")"
  ACTUAL_VALUE="$(/usr/libexec/PlistBuddy -c "Print :${PLIST_KEY}" "${APP_INFO_PLIST}")"
  if [[ "${ACTUAL_VALUE}" != "${EXPECTED_VALUE}" ]]; then
    echo "Release verification failed: ${PLIST_KEY} is ${ACTUAL_VALUE}, expected ${EXPECTED_VALUE}." >&2
    exit 1
  fi
done

while IFS= read -r -d '' symlink_path; do
  case "${symlink_path}" in
    "${APP_PATH}"/Contents/Frameworks/*.framework/Versions/*)
      # Standard macOS framework layout. codesign --deep below verifies the
      # referenced framework code; links elsewhere remain prohibited.
      ;;
    *)
      echo "Release verification failed: unexpected symbolic link: ${symlink_path}" >&2
      exit 1
      ;;
  esac
done < <(/usr/bin/find "${APP_PATH}/Contents" -type l -print0)

is_allowed_embedded_code_path() {
  local candidate="$1"
  [[ "${candidate}" == "${APP_BINARY}" ]] && return 0
  [[ "${candidate}" == "${NATIVE_HOST_BINARY}" ]] && return 0
  case "${candidate}" in
    "${APP_PATH}"/Contents/Frameworks/*.framework/*|\
    "${APP_PATH}"/Contents/PlugIns/*.appex/Contents/MacOS/*|\
    "${APP_PATH}"/Contents/Library/LoginItems/*.app/Contents/MacOS/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

while IFS= read -r -d '' EXECUTABLE_CANDIDATE; do
  if ! is_allowed_embedded_code_path "${EXECUTABLE_CANDIDATE}"; then
    echo "Release verification failed: unexpected executable file: ${EXECUTABLE_CANDIDATE}" >&2
    exit 1
  fi
done < <(/usr/bin/find "${APP_PATH}/Contents" -type f -perm -111 -print0)

codesign --verify --deep --strict --verbose=2 "${APP_PATH}" >/dev/null
codesign --verify --strict --verbose=2 "${NATIVE_HOST_BINARY}" >/dev/null
if [[ "$(/usr/bin/lipo -archs "${APP_BINARY}" 2>/dev/null || true)" != "arm64" \
      || "$(/usr/bin/lipo -archs "${NATIVE_HOST_BINARY}" 2>/dev/null || true)" != "arm64" ]]; then
  echo "Release verification failed: app and native host must both be arm64-only." >&2
  exit 1
fi

# The base app is currently single-binary, but the 1.0 distribution may add a
# signed Sparkle framework and a signed Safari app extension. Both locations
# are explicitly allowlisted above; any other native payload is rejected.
MACHO_COUNT=0
while IFS= read -r -d '' CANDIDATE_PATH; do
  if /usr/bin/file -b "${CANDIDATE_PATH}" | /usr/bin/grep -Fq 'Mach-O'; then
    MACHO_COUNT=$((MACHO_COUNT + 1))
    if ! is_allowed_embedded_code_path "${CANDIDATE_PATH}"; then
      echo "Release verification failed: unexpected embedded executable: ${CANDIDATE_PATH}" >&2
      exit 1
    fi
  fi
done < <(/usr/bin/find "${APP_PATH}/Contents" -type f -print0)

if [[ "${MACHO_COUNT}" -ne 2 ]]; then
  echo "Release verification failed: expected exactly the app and native-host Mach-O executables; found ${MACHO_COUNT}." >&2
  exit 1
fi

SIGNING_DETAILS="$(codesign -d --verbose=4 "${APP_PATH}" 2>&1)"
NATIVE_HOST_SIGNING_DETAILS="$(codesign -d --verbose=4 "${NATIVE_HOST_BINARY}" 2>&1)"
if ! /usr/bin/grep -Eq 'flags=.*runtime' <<<"${SIGNING_DETAILS}"; then
  echo "Release verification failed: hardened runtime is not enabled." >&2
  exit 1
fi
if ! /usr/bin/grep -Eq 'flags=.*runtime' <<<"${NATIVE_HOST_SIGNING_DETAILS}"; then
  echo "Release verification failed: native-host hardened runtime is not enabled." >&2
  exit 1
fi
if ! /usr/bin/grep -Fq 'Identifier=local.codex.ClaudePromptTranslator.NativeHost' \
    <<<"${NATIVE_HOST_SIGNING_DETAILS}"; then
  echo "Release verification failed: native-host signing identifier is unexpected." >&2
  exit 1
fi

if [[ "${PUBLIC_RELEASE}" == "1" ]]; then
  if [[ -z "${EXPECTED_TEAM_ID:-}" ]]; then
    echo "Public Release verification failed: set EXPECTED_TEAM_ID to the Developer ID Team ID." >&2
    exit 1
  fi
  if ! /usr/bin/grep -Fq 'Authority=Developer ID Application:' <<<"${SIGNING_DETAILS}"; then
    echo "Public Release verification failed: Developer ID Application signature required." >&2
    exit 1
  fi
  if ! /usr/bin/grep -Fq 'Authority=Developer ID Application:' <<<"${NATIVE_HOST_SIGNING_DETAILS}"; then
    echo "Public Release verification failed: native-host Developer ID signature required." >&2
    exit 1
  fi
  if ! /usr/bin/grep -Eq '^Timestamp=.+' <<<"${SIGNING_DETAILS}"; then
    echo "Public Release verification failed: secure signing timestamp required." >&2
    exit 1
  fi
  if ! /usr/bin/grep -Eq '^Timestamp=.+' <<<"${NATIVE_HOST_SIGNING_DETAILS}"; then
    echo "Public Release verification failed: native-host secure signing timestamp required." >&2
    exit 1
  fi
  if ! /usr/bin/grep -Fq "TeamIdentifier=${EXPECTED_TEAM_ID}" <<<"${SIGNING_DETAILS}"; then
    echo "Public Release verification failed: signing Team ID does not match EXPECTED_TEAM_ID." >&2
    exit 1
  fi
  if ! /usr/bin/grep -Fq "TeamIdentifier=${EXPECTED_TEAM_ID}" <<<"${NATIVE_HOST_SIGNING_DETAILS}"; then
    echo "Public Release verification failed: native-host Team ID does not match EXPECTED_TEAM_ID." >&2
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
  'CPT_TEST_BROWSER_NATIVE_SOCKET' \
  'translate.googleapis.com' \
  'GoogleTranslateClient'; do
  if /usr/bin/strings "${APP_BINARY}" "${NATIVE_HOST_BINARY}" \
      | /usr/bin/grep -Fq -- "${FORBIDDEN_MARKER}"; then
    echo "Release verification failed: forbidden marker present: ${FORBIDDEN_MARKER}" >&2
    exit 1
  fi
done

ENTITLEMENTS="$(codesign -d --entitlements - "${APP_PATH}" 2>/dev/null || true)"

# Network-capable frameworks are allowed only for explicitly enabled cloud,
# update and model-download features. Whether those requests are user-approved
# is enforced by runtime policy, not by a brittle imported-symbol heuristic.
# Keep the standard App Sandbox network entitlement visible in the report so a
# reviewer can verify it against the release configuration.
if /usr/bin/grep -Eq 'com\.apple\.security\.network\.(client|server)' <<<"${ENTITLEMENTS}"; then
  echo "Release verification note: network entitlement present; verify runtime host allowlists before publishing."
fi

if [[ "${REQUIRE_GATEKEEPER}" == "1" ]]; then
  if [[ "${PUBLIC_RELEASE}" != "1" ]]; then
    echo "Gatekeeper validation is a public-release gate; pass --public as well." >&2
    exit 2
  fi
  xcrun stapler validate "${APP_PATH}"
  spctl --assess --type execute --verbose=4 "${APP_PATH}"
fi

if [[ "${PUBLIC_RELEASE}" == "1" ]]; then
  echo "Verified public-signing prerequisites for ${APP_PATH}"
else
  echo "Verified local Release app ${APP_PATH}; notarization and Gatekeeper remain external public-release gates."
fi
