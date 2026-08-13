#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "Usage: $0 APP_PATH ZIP_PATH OUTPUT_JSON local-test-unnotarized|public-notarized" >&2
  exit 2
fi

APP_PATH="$1"
ZIP_PATH="$2"
OUTPUT_PATH="$3"
RELEASE_CHANNEL="$4"
if [[ "${RELEASE_CHANNEL}" != "local-test-unnotarized" \
      && "${RELEASE_CHANNEL}" != "public-notarized" ]]; then
  echo "Refusing unknown release channel: ${RELEASE_CHANNEL}" >&2
  exit 2
fi
APP_NAME="ClaudePromptTranslator"
APP_BINARY="${APP_PATH}/Contents/MacOS/${APP_NAME}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -x "${APP_BINARY}" || ! -f "${ZIP_PATH}" ]]; then
  echo "Cannot write manifest for an incomplete artifact." >&2
  exit 1
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_PATH}/Contents/Info.plist")"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${APP_PATH}/Contents/Info.plist")"
git_sha="$(git -C "${ROOT_DIR}" rev-parse HEAD)"
binary_sha="$(/usr/bin/shasum -a 256 "${APP_BINARY}" | /usr/bin/awk '{print $1}')"
zip_sha="$(/usr/bin/shasum -a 256 "${ZIP_PATH}" | /usr/bin/awk '{print $1}')"
app_bytes="$(/usr/bin/du -sk "${APP_PATH}" | /usr/bin/awk '{print $1 * 1024}')"
zip_bytes="$(/usr/bin/stat -f '%z' "${ZIP_PATH}")"

mkdir -p "$(dirname "${OUTPUT_PATH}")"
tmp_path="$(mktemp "$(dirname "${OUTPUT_PATH}")/.release-manifest.XXXXXX")"
trap 'rm -f "${tmp_path}"' EXIT
cat >"${tmp_path}" <<EOF
{
  "app": "${APP_NAME}",
  "bundleID": "${bundle_id}",
  "version": "${version}",
  "releaseChannel": "${RELEASE_CHANNEL}",
  "gitSHA": "${git_sha}",
  "appBytes": ${app_bytes},
  "zipBytes": ${zip_bytes},
  "executableSHA256": "${binary_sha}",
  "zipSHA256": "${zip_sha}"
}
EOF
mv -f "${tmp_path}" "${OUTPUT_PATH}"
trap - EXIT
echo "Wrote release manifest: ${OUTPUT_PATH}"
