#!/usr/bin/env bash
set -euo pipefail

HOST_NAME="com.on1ymyse1f.InvisibleTranslator"
EXPECTED_BUNDLE_ID="local.codex.ClaudePromptTranslator"
APP_PATH="${HOME}/Applications/ClaudePromptTranslator.app"
BROWSER="chrome"
EXTENSION_ID=""

usage() {
  echo "Usage: $0 --extension-id <32 lowercase a-p chars> [--app /absolute/App.app] [--browser chrome|chromium]" >&2
}

while (($#)); do
  case "$1" in
    --extension-id)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      EXTENSION_ID="$2"
      shift 2
      ;;
    --app)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      APP_PATH="$2"
      shift 2
      ;;
    --browser)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      BROWSER="$2"
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ ! "${EXTENSION_ID}" =~ ^[a-p]{32}$ ]]; then
  echo "Refusing to install: pass the explicit 32-character ID shown for the Chromium extension on this Mac." >&2
  echo "This installer does not assign or prove a fixed production/store extension ID." >&2
  exit 2
fi
if [[ "${APP_PATH}" != /* || "${APP_PATH}" != *.app || -L "${APP_PATH}" ]]; then
  echo "Refusing to install: --app must be an absolute, non-symlink app bundle path." >&2
  exit 2
fi

INFO_PLIST="${APP_PATH}/Contents/Info.plist"
HOST_EXECUTABLE="${APP_PATH}/Contents/MacOS/ClaudePromptTranslatorNativeHost"
if [[ ! -f "${INFO_PLIST}" ]]; then
  echo "Refusing to install: app Info.plist is missing." >&2
  exit 1
fi
ACTUAL_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${INFO_PLIST}" 2>/dev/null || true)"
if [[ "${ACTUAL_BUNDLE_ID}" != "${EXPECTED_BUNDLE_ID}" ]]; then
  echo "Refusing to install: unexpected app bundle identifier." >&2
  exit 1
fi
if [[ ! -f "${HOST_EXECUTABLE}" || ! -x "${HOST_EXECUTABLE}" || -L "${HOST_EXECUTABLE}" ]]; then
  echo "Refusing to install: this app build does not contain the signed native host helper." >&2
  exit 1
fi
APP_REAL_PATH="$(realpath "${APP_PATH}")"
HOST_REAL_PATH="$(realpath "${HOST_EXECUTABLE}")"
if [[ "${HOST_REAL_PATH}" != "${APP_REAL_PATH}/Contents/MacOS/ClaudePromptTranslatorNativeHost" ]]; then
  echo "Refusing to install: native host helper resolves outside the expected app location." >&2
  exit 1
fi
HOST_EXECUTABLE="${HOST_REAL_PATH}"
codesign --verify --deep --strict "${APP_PATH}" >/dev/null
codesign --verify --strict "${HOST_EXECUTABLE}" >/dev/null
APP_SIGNING_DETAILS="$(codesign -d --verbose=4 "${APP_PATH}" 2>&1)"
HOST_SIGNING_DETAILS="$(codesign -d --verbose=4 "${HOST_EXECUTABLE}" 2>&1)"
if ! grep -Fq 'Identifier=local.codex.ClaudePromptTranslator.NativeHost' \
    <<<"${HOST_SIGNING_DETAILS}"; then
  echo "Refusing to install: native host has an unexpected signing identifier." >&2
  exit 1
fi
APP_TEAM_ID="$(awk -F= '/^TeamIdentifier=/{print $2; exit}' <<<"${APP_SIGNING_DETAILS}")"
HOST_TEAM_ID="$(awk -F= '/^TeamIdentifier=/{print $2; exit}' <<<"${HOST_SIGNING_DETAILS}")"
if [[ -n "${APP_TEAM_ID}" && "${APP_TEAM_ID}" != "not set" \
      && "${APP_TEAM_ID}" != "${HOST_TEAM_ID}" ]]; then
  echo "Refusing to install: app and native host Team IDs do not match." >&2
  exit 1
fi

case "${BROWSER}" in
  chrome)
    HOST_DIRECTORY="${HOME}/Library/Application Support/Google/Chrome/NativeMessagingHosts"
    ;;
  chromium)
    HOST_DIRECTORY="${HOME}/Library/Application Support/Chromium/NativeMessagingHosts"
    ;;
  *)
    echo "Refusing to install: unsupported browser '${BROWSER}'." >&2
    exit 2
    ;;
esac

umask 077
if [[ -L "${HOST_DIRECTORY}" ]]; then
  echo "Refusing to install: native-host directory must not be a symbolic link." >&2
  exit 1
fi
mkdir -p "${HOST_DIRECTORY}"
if [[ "$(stat -f '%u' "${HOST_DIRECTORY}")" != "$(id -u)" ]]; then
  echo "Refusing to install: native-host directory is not owned by the current user." >&2
  exit 1
fi
DESTINATION="${HOST_DIRECTORY}/${HOST_NAME}.json"
if [[ -L "${DESTINATION}" ]]; then
  echo "Refusing to install: existing native-host manifest is a symbolic link." >&2
  exit 1
fi
TEMP_MANIFEST="$(mktemp "${HOST_DIRECTORY}/.${HOST_NAME}.XXXXXX")"
trap 'rm -f -- "${TEMP_MANIFEST}"' EXIT

plutil -create xml1 "${TEMP_MANIFEST}"
plutil -insert name -string "${HOST_NAME}" "${TEMP_MANIFEST}"
plutil -insert description -string "Invisible Translator local bridge" "${TEMP_MANIFEST}"
plutil -insert path -string "${HOST_EXECUTABLE}" "${TEMP_MANIFEST}"
plutil -insert type -string "stdio" "${TEMP_MANIFEST}"
plutil -insert allowed_origins -array "${TEMP_MANIFEST}"
plutil -insert allowed_origins.0 -string "chrome-extension://${EXTENSION_ID}/" "${TEMP_MANIFEST}"
plutil -convert json "${TEMP_MANIFEST}"
plutil -lint "${TEMP_MANIFEST}" >/dev/null
chmod 600 "${TEMP_MANIFEST}"
mv -f "${TEMP_MANIFEST}" "${DESTINATION}"
trap - EXIT
echo "Installed native-host manifest for ${BROWSER}: ${DESTINATION}"
echo "The manifest grants only chrome-extension://${EXTENSION_ID}/ and does not enable any website by itself."
