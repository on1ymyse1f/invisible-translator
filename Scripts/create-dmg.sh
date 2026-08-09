#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ClaudePromptTranslator"
DISPLAY_NAME="无感翻译"
INFO_PLIST="${ROOT_DIR}/Packaging/Info.plist"
DIST_DIR="${ROOT_DIR}/dist"
DIST_ZIP_PATH="${DIST_DIR}/${APP_NAME}.app.zip"
SOURCE_APP_PATH="${SOURCE_APP_PATH:-${HOME}/Applications/${APP_NAME}.app}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PLIST}")"
DMG_PATH="${DMG_PATH:-${DIST_DIR}/${APP_NAME}-${VERSION}.dmg}"
VOLUME_NAME="${VOLUME_NAME:-${DISPLAY_NAME} ${VERSION}}"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}.dmg.XXXXXX")"
WORK_DMG_PATH="${STAGING_DIR}/${APP_NAME}-${VERSION}.dmg"
DMG_ROOT="${STAGING_DIR}/dmg-root"
MOUNT_DIR="${STAGING_DIR}/mounted"
VERIFY_SCRIPT="${ROOT_DIR}/Scripts/verify-release-app.sh"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
MOUNTED=0

validate_dmg_destination() {
  local candidate="$1"
  if [[ "${candidate}" != /* ]]; then
    echo "Refusing to create DMG: DMG_PATH must be an absolute path." >&2
    exit 1
  fi
  if [[ "$(basename "${candidate}")" != "${APP_NAME}-${VERSION}.dmg" ]]; then
    echo "Refusing to create DMG: destination must end with /${APP_NAME}-${VERSION}.dmg." >&2
    exit 1
  fi
  if [[ "${candidate}" == "/" || "${candidate}" == "${HOME}" || "${candidate}" == "${ROOT_DIR}" ]]; then
    echo "Refusing to create DMG: unsafe destination ${candidate}." >&2
    exit 1
  fi
  if [[ -d "${candidate}" ]]; then
    echo "Refusing to create DMG: destination is an existing directory." >&2
    exit 1
  fi
}

validate_source_app_path() {
  local candidate="$1"
  if [[ "${candidate}" != /* ]]; then
    echo "Refusing to package: SOURCE_APP_PATH must be an absolute path." >&2
    exit 1
  fi
  if [[ "$(basename "${candidate}")" != "${APP_NAME}.app" ]]; then
    echo "Refusing to package: source must end with /${APP_NAME}.app." >&2
    exit 1
  fi
  if [[ "${candidate}" == "/" || "${candidate}" == "${HOME}" || "${candidate}" == "${ROOT_DIR}" ]]; then
    echo "Refusing to package: unsafe source ${candidate}." >&2
    exit 1
  fi
  if [[ -L "${candidate}" ]]; then
    echo "Refusing to package: SOURCE_APP_PATH must not be a symbolic link." >&2
    exit 1
  fi
}

validate_volume_name() {
  local candidate="$1"
  if [[ -z "${candidate}" || "${candidate}" == "." || "${candidate}" == ".." \
      || "${candidate}" == *"/"* || "${candidate}" == *":"* ]]; then
    echo "Refusing to create DMG: VOLUME_NAME contains an unsafe value." >&2
    exit 1
  fi
  if [[ "${#candidate}" -gt 64 ]] \
      || printf '%s' "${candidate}" | LC_ALL=C /usr/bin/grep -q '[[:cntrl:]]'; then
    echo "Refusing to create DMG: VOLUME_NAME is too long or contains control characters." >&2
    exit 1
  fi
}

cleanup() {
  if [[ "${MOUNTED}" == "1" ]]; then
    hdiutil detach "${MOUNT_DIR}" >/dev/null 2>&1 || true
  fi
  rm -rf "${STAGING_DIR}"
}
trap cleanup EXIT

validate_dmg_destination "${DMG_PATH}"
validate_source_app_path "${SOURCE_APP_PATH}"
validate_volume_name "${VOLUME_NAME}"

cd "${ROOT_DIR}"

if [[ -z "${NOTARY_PROFILE}" ]]; then
  echo "Public DMG creation requires NOTARY_PROFILE for xcrun notarytool." >&2
  echo "No local-only DMG was created, to avoid an identity-bearing unnotarized artifact." >&2
  exit 1
fi

if [[ "${SKIP_APP_PACKAGE:-0}" != "1" ]]; then
  "${ROOT_DIR}/Scripts/package-app.sh"
fi

if [[ ! -d "${SOURCE_APP_PATH}" && -f "${DIST_ZIP_PATH}" ]]; then
  ARCHIVE_SOURCE_DIR="${STAGING_DIR}/archive-source"
  mkdir -p "${ARCHIVE_SOURCE_DIR}"
  ditto -x -k "${DIST_ZIP_PATH}" "${ARCHIVE_SOURCE_DIR}"
  SOURCE_APP_PATH="${ARCHIVE_SOURCE_DIR}/${APP_NAME}.app"
fi

if [[ ! -d "${SOURCE_APP_PATH}" ]]; then
  echo "App bundle not found: ${SOURCE_APP_PATH}" >&2
  echo "Run Scripts/package-app.sh first, or rerun without SKIP_APP_PACKAGE=1." >&2
  exit 1
fi

"${VERIFY_SCRIPT}" --public "${SOURCE_APP_PATH}"
xcrun stapler validate "${SOURCE_APP_PATH}"
spctl --assess --type execute --verbose=4 "${SOURCE_APP_PATH}"

DEVELOPER_ID_IDENTITY="$(
  codesign -d --verbose=4 "${SOURCE_APP_PATH}" 2>&1 \
    | awk -F '=' '/^Authority=Developer ID Application:/ { print $2; exit }'
)"
if [[ -z "${DEVELOPER_ID_IDENTITY}" ]]; then
  echo "Developer ID Application authority not found on ${SOURCE_APP_PATH}." >&2
  exit 1
fi

rm -rf "${DMG_ROOT}"
mkdir -p "${DMG_ROOT}"
STAGED_SOURCE_APP="${STAGING_DIR}/source/${APP_NAME}.app"
mkdir -p "$(dirname "${STAGED_SOURCE_APP}")"
ditto --norsrc --noextattr --noacl --noqtn "${SOURCE_APP_PATH}" "${STAGED_SOURCE_APP}"
xattr -cr "${STAGED_SOURCE_APP}" 2>/dev/null || true
"${VERIFY_SCRIPT}" --public "${STAGED_SOURCE_APP}"
xcrun stapler validate "${STAGED_SOURCE_APP}"
spctl --assess --type execute --verbose=4 "${STAGED_SOURCE_APP}"

ditto --norsrc --noextattr --noacl --noqtn "${STAGED_SOURCE_APP}" "${DMG_ROOT}/${APP_NAME}.app"
ln -s /Applications "${DMG_ROOT}/Applications"
"${VERIFY_SCRIPT}" --public "${DMG_ROOT}/${APP_NAME}.app"
xcrun stapler validate "${DMG_ROOT}/${APP_NAME}.app"
spctl --assess --type execute --verbose=4 "${DMG_ROOT}/${APP_NAME}.app"

mkdir -p "${DIST_DIR}"
if diskutil image create from --help >/dev/null 2>&1; then
  diskutil image create from \
    --volumeName "${VOLUME_NAME}" \
    --format UDZO \
    "${DMG_ROOT}" \
    "${WORK_DMG_PATH}" >/dev/null
else
  hdiutil create \
    -volname "${VOLUME_NAME}" \
    -srcfolder "${DMG_ROOT}" \
    -ov \
    -format UDZO \
    "${WORK_DMG_PATH}" >/dev/null
fi

codesign --force --timestamp --sign "${DEVELOPER_ID_IDENTITY}" "${WORK_DMG_PATH}" >/dev/null
xcrun notarytool submit "${WORK_DMG_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait
xcrun stapler staple "${WORK_DMG_PATH}"
xcrun stapler validate "${WORK_DMG_PATH}"
hdiutil verify "${WORK_DMG_PATH}" >/dev/null
spctl --assess --type open --context context:primary-signature --verbose=4 "${WORK_DMG_PATH}"

# Verify the exact app a user receives after mounting the finished image. This
# also applies when SKIP_APP_PACKAGE=1, so an old network-enabled build cannot
# be repackaged merely because its code signature is valid.
mkdir -p "${MOUNT_DIR}"
hdiutil attach -readonly -nobrowse -mountpoint "${MOUNT_DIR}" "${WORK_DMG_PATH}" >/dev/null
MOUNTED=1
"${VERIFY_SCRIPT}" --public "${MOUNT_DIR}/${APP_NAME}.app"
xcrun stapler validate "${MOUNT_DIR}/${APP_NAME}.app"
spctl --assess --type execute --verbose=4 "${MOUNT_DIR}/${APP_NAME}.app"
hdiutil detach "${MOUNT_DIR}" >/dev/null
MOUNTED=0

# Do not expose a partial or unnotarized DMG at the final path.
mkdir -p "$(dirname "${DMG_PATH}")"
mv -f "${WORK_DMG_PATH}" "${DMG_PATH}"

echo "Created ${DMG_PATH}"
echo "SHA256: $(shasum -a 256 "${DMG_PATH}" | awk '{print $1}')"
