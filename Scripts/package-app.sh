#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ClaudePromptTranslator"
INSTALL_APP_DIR="${INSTALL_APP_DIR:-${HOME}/Applications/${APP_NAME}.app}"
DIST_DIR="${ROOT_DIR}/dist"
DIST_ZIP_PATH="${DIST_DIR}/${APP_NAME}.app.zip"
LEGACY_DIST_APP_DIR="${DIST_DIR}/${APP_NAME}.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${ROOT_DIR}/Packaging/Info.plist")"
DIST_DMG_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}.dmg"
EXECUTABLE_PATH="${ROOT_DIR}/.build/release/${APP_NAME}"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}.XXXXXX")"
APP_DIR="${STAGING_DIR}/${APP_NAME}.app"
VERIFY_SCRIPT="${ROOT_DIR}/Scripts/verify-release-app.sh"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
EXPECTED_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${ROOT_DIR}/Packaging/Info.plist")"
INSTALL_SWAP_DIR=""
WAS_INSTALLED_APP_RUNNING=0

validate_install_destination() {
  local candidate="$1"
  if [[ "${candidate}" != /* ]]; then
    echo "Refusing to install: INSTALL_APP_DIR must be an absolute path." >&2
    exit 1
  fi
  if [[ "$(basename "${candidate}")" != "${APP_NAME}.app" ]]; then
    echo "Refusing to install: destination must end with /${APP_NAME}.app." >&2
    exit 1
  fi
  if [[ "${candidate}" == */ ]]; then
    echo "Refusing to install: destination must not have a trailing slash." >&2
    exit 1
  fi
  if [[ "${candidate}" == "/" || "${candidate}" == "${HOME}" || "${candidate}" == "${ROOT_DIR}" ]]; then
    echo "Refusing to install: unsafe destination ${candidate}." >&2
    exit 1
  fi
  if [[ -L "${candidate}" ]]; then
    echo "Refusing to install: destination must not be a symbolic link." >&2
    exit 1
  fi
  if [[ -e "${candidate}" && ! -d "${candidate}" ]]; then
    echo "Refusing to install: existing destination is not an app bundle directory." >&2
    exit 1
  fi
  if [[ -d "${candidate}" ]]; then
    local existing_plist="${candidate}/Contents/Info.plist"
    if [[ ! -f "${existing_plist}" ]]; then
      echo "Refusing to replace an existing directory without an app Info.plist." >&2
      exit 1
    fi
    local existing_bundle_id
    existing_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${existing_plist}" 2>/dev/null || true)"
    if [[ "${existing_bundle_id}" != "${EXPECTED_BUNDLE_ID}" ]]; then
      echo "Refusing to replace app with bundle id ${existing_bundle_id:-<missing>}." >&2
      exit 1
    fi
  fi
}

terminate_installed_app_if_running() {
  local terminated_count
  terminated_count="$(/usr/bin/swift -e '
import AppKit
import Darwin
import Foundation

let bundleIdentifier = CommandLine.arguments[1]
let expectedPath = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.path
let applications = NSRunningApplication
    .runningApplications(withBundleIdentifier: bundleIdentifier)
    .filter { $0.bundleURL?.standardizedFileURL.path == expectedPath }

for application in applications {
    guard application.terminate() else {
        fputs("Could not request a graceful application termination.\n", stderr)
        exit(2)
    }
    let processIdentifier = application.processIdentifier
    func processIsAlive() -> Bool {
        errno = 0
        if kill(processIdentifier, 0) == 0 {
            return true
        }
        return errno == EPERM
    }
    let deadline = Date().addingTimeInterval(5)
    while processIsAlive(), Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
    }
    guard !processIsAlive() else {
        fputs("The installed application did not terminate within five seconds.\n", stderr)
        exit(3)
    }
}

print(applications.count)
' "${EXPECTED_BUNDLE_ID}" "${INSTALL_APP_DIR}")"

  if [[ ! "${terminated_count}" =~ ^[0-9]+$ ]]; then
    echo "Could not determine the installed app process state." >&2
    exit 1
  fi
  WAS_INSTALLED_APP_RUNNING="${terminated_count}"
  if (( WAS_INSTALLED_APP_RUNNING > 0 )); then
    echo "Gracefully stopped ${WAS_INSTALLED_APP_RUNNING} running installed instance(s)."
  fi
}

relaunch_installed_app_if_needed() {
  if (( WAS_INSTALLED_APP_RUNNING == 0 )); then
    return 0
  fi

  /usr/bin/open "${INSTALL_APP_DIR}"
  /usr/bin/swift -e '
import AppKit
import Foundation

let bundleIdentifier = CommandLine.arguments[1]
let expectedPath = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.path
let deadline = Date().addingTimeInterval(5)

repeat {
    if let application = NSRunningApplication
        .runningApplications(withBundleIdentifier: bundleIdentifier)
        .first(where: { $0.bundleURL?.standardizedFileURL.path == expectedPath }) {
        print("Relaunched installed app with PID \(application.processIdentifier).")
        exit(0)
    }
    Thread.sleep(forTimeInterval: 0.05)
} while Date() < deadline

fputs("The newly installed application did not launch within five seconds.\n", stderr)
exit(1)
' "${EXPECTED_BUNDLE_ID}" "${INSTALL_APP_DIR}"
}

cleanup() {
  rm -rf "${STAGING_DIR}"
  if [[ -n "${INSTALL_SWAP_DIR}" && -d "${INSTALL_SWAP_DIR}" \
        && "$(basename "${INSTALL_SWAP_DIR}")" == ".${APP_NAME}.install."* ]]; then
    rm -rf -- "${INSTALL_SWAP_DIR}"
  fi
}
trap cleanup EXIT

validate_install_destination "${INSTALL_APP_DIR}"

cd "${ROOT_DIR}"

if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

"${ROOT_DIR}/Scripts/test.sh"
swift build -c release

# Privacy regression guard: no debug-only process control or diagnostics entry
# point may enter production.
for DEBUG_MARKER in \
  '--self-test-paste' \
  '--self-test-set-input' \
  '--self-test-inspect-input' \
  '--self-test-selection' \
  '--self-test-inline' \
  '--self-test-response' \
  'CPT_DEBUG_SELECTION' \
  'CPT_DEBUG_SELECTION_PID' \
  'CPT_DEBUG_DELIVERY'; do
  if /usr/bin/strings "${EXECUTABLE_PATH}" | /usr/bin/grep -Fq -- "${DEBUG_MARKER}"; then
    echo "Refusing to package: debug marker is present in the Release binary: ${DEBUG_MARKER}" >&2
    exit 1
  fi
done
if /usr/bin/strings "${EXECUTABLE_PATH}" | /usr/bin/grep -Fq -- "translate.googleapis.com"; then
  echo "Refusing to package: compatibility-network provider is present in the Release binary." >&2
  exit 1
fi

mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"
cp "${EXECUTABLE_PATH}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp "${ROOT_DIR}/Packaging/Info.plist" "${APP_DIR}/Contents/Info.plist"
cp "${ROOT_DIR}/Resources/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"
chmod +x "${APP_DIR}/Contents/MacOS/${APP_NAME}"
xattr -cr "${APP_DIR}" 2>/dev/null || true

SIGN_IDENTITY="$(
  security find-identity -p codesigning -v 2>/dev/null \
    | awk -F '"' '
        /Developer ID Application/ { print $2; found = 1; exit }
        /Apple Development|Mac Developer/ && fallback == "" { fallback = $2 }
        END { if (!found && fallback != "") print fallback }
      '
)"

if [[ -n "${SIGN_IDENTITY}" ]]; then
  if [[ "${SIGN_IDENTITY}" == Developer\ ID\ Application:* ]]; then
    echo "Signing with an available Developer ID Application identity."
    codesign --force --deep --timestamp --options runtime --sign "${SIGN_IDENTITY}" "${APP_DIR}" >/dev/null
  else
    echo "Signing with an available local development identity."
    codesign --force --deep --timestamp=none --options runtime --sign "${SIGN_IDENTITY}" "${APP_DIR}" >/dev/null
  fi
else
  echo "Signing ad hoc; Accessibility permission may need to be re-granted after rebuilds."
  codesign --force --deep --options runtime --sign - "${APP_DIR}" >/dev/null
fi

xattr -cr "${APP_DIR}" 2>/dev/null || true
codesign --verify --deep --strict --verbose=2 "${APP_DIR}" >/dev/null
"${VERIFY_SCRIPT}" "${APP_DIR}"

INSTALL_PARENT="$(dirname "${INSTALL_APP_DIR}")"
mkdir -p "${INSTALL_PARENT}"
validate_install_destination "${INSTALL_APP_DIR}"
INSTALL_SWAP_DIR="$(mktemp -d "${INSTALL_PARENT}/.${APP_NAME}.install.XXXXXX")"
STAGED_INSTALL_APP="${INSTALL_SWAP_DIR}/${APP_NAME}.app"
PREVIOUS_INSTALL_APP="${INSTALL_SWAP_DIR}/previous-${APP_NAME}.app"
FAILED_INSTALL_APP="${INSTALL_SWAP_DIR}/failed-${APP_NAME}.app"
mv "${APP_DIR}" "${STAGED_INSTALL_APP}"
terminate_installed_app_if_running

if [[ -d "${INSTALL_APP_DIR}" ]]; then
  mv "${INSTALL_APP_DIR}" "${PREVIOUS_INSTALL_APP}"
fi
if ! mv "${STAGED_INSTALL_APP}" "${INSTALL_APP_DIR}"; then
  if [[ -d "${PREVIOUS_INSTALL_APP}" ]]; then
    mv "${PREVIOUS_INSTALL_APP}" "${INSTALL_APP_DIR}"
  fi
  relaunch_installed_app_if_needed || true
  echo "Installation failed before the new app could be moved into place." >&2
  exit 1
fi

xattr -cr "${INSTALL_APP_DIR}" 2>/dev/null || true
if ! codesign --verify --deep --strict --verbose=2 "${INSTALL_APP_DIR}" >/dev/null \
  || ! "${VERIFY_SCRIPT}" "${INSTALL_APP_DIR}"; then
  mv "${INSTALL_APP_DIR}" "${FAILED_INSTALL_APP}"
  if [[ -d "${PREVIOUS_INSTALL_APP}" ]]; then
    mv "${PREVIOUS_INSTALL_APP}" "${INSTALL_APP_DIR}"
  fi
  relaunch_installed_app_if_needed || true
  echo "Installation verification failed; the previous app was restored." >&2
  exit 1
fi

if ! relaunch_installed_app_if_needed; then
  mv "${INSTALL_APP_DIR}" "${FAILED_INSTALL_APP}"
  if [[ -d "${PREVIOUS_INSTALL_APP}" ]]; then
    mv "${PREVIOUS_INSTALL_APP}" "${INSTALL_APP_DIR}"
    /usr/bin/open "${INSTALL_APP_DIR}" || true
  fi
  echo "The new app could not be relaunched; the previous app was restored." >&2
  exit 1
fi

if [[ -d "${PREVIOUS_INSTALL_APP}" ]]; then
  rm -rf -- "${PREVIOUS_INSTALL_APP}"
fi
rmdir "${INSTALL_SWAP_DIR}"
INSTALL_SWAP_DIR=""

mkdir -p "${DIST_DIR}"
rm -rf "${LEGACY_DIST_APP_DIR}"
rm -f "${DIST_ZIP_PATH}"
rm -f "${DIST_DMG_PATH}"

if [[ "${SIGN_IDENTITY}" != Developer\ ID\ Application:* || -z "${NOTARY_PROFILE}" ]]; then
  if [[ "${SIGN_IDENTITY}" != Developer\ ID\ Application:* ]]; then
    echo "Skipped public ZIP: Developer ID Application identity is unavailable."
  else
    echo "Skipped public ZIP: NOTARY_PROFILE is unavailable."
  fi
  echo "Installed local-test app ${INSTALL_APP_DIR}"
  echo "Run: open \"${INSTALL_APP_DIR}\""
  exit 0
fi

# A raw .app inside a FileProvider-backed project folder can immediately gain a
# FinderInfo xattr and fail strict code-signature verification. Build the GitHub
# artifact in a clean temporary directory, verify it, then store it as a ZIP.
DIST_STAGE_DIR="${STAGING_DIR}/dist-stage"
DIST_STAGE_APP="${DIST_STAGE_DIR}/${APP_NAME}.app"
mkdir -p "${DIST_STAGE_DIR}"
ditto --norsrc --noextattr --noacl --noqtn "${INSTALL_APP_DIR}" "${DIST_STAGE_APP}"
"${VERIFY_SCRIPT}" --public "${DIST_STAGE_APP}"

NOTARY_SUBMISSION_ZIP="${STAGING_DIR}/notary-submission.zip"
ditto -c -k --keepParent --norsrc --noextattr --noacl --noqtn \
  "${DIST_STAGE_APP}" \
  "${NOTARY_SUBMISSION_ZIP}"
xcrun notarytool submit "${NOTARY_SUBMISSION_ZIP}" \
  --keychain-profile "${NOTARY_PROFILE}" \
  --wait
xcrun stapler staple "${DIST_STAGE_APP}"
xcrun stapler validate "${DIST_STAGE_APP}"
spctl --assess --type execute --verbose=4 "${DIST_STAGE_APP}"

# Keep the locally installed Developer ID build equivalent to the public ZIP.
xcrun stapler staple "${INSTALL_APP_DIR}"
xcrun stapler validate "${INSTALL_APP_DIR}"
spctl --assess --type execute --verbose=4 "${INSTALL_APP_DIR}"

FINAL_ZIP_PATH="${STAGING_DIR}/${APP_NAME}.app.zip"
ditto -c -k --keepParent --norsrc --noextattr --noacl --noqtn \
  "${DIST_STAGE_APP}" \
  "${FINAL_ZIP_PATH}"

DIST_VERIFY_DIR="${STAGING_DIR}/dist-zip-verify"
mkdir -p "${DIST_VERIFY_DIR}"
ditto -x -k "${FINAL_ZIP_PATH}" "${DIST_VERIFY_DIR}"
"${VERIFY_SCRIPT}" --public "${DIST_VERIFY_DIR}/${APP_NAME}.app"
xcrun stapler validate "${DIST_VERIFY_DIR}/${APP_NAME}.app"
spctl --assess --type execute --verbose=4 "${DIST_VERIFY_DIR}/${APP_NAME}.app"

INSTALL_SHA="$(shasum -a 256 "${INSTALL_APP_DIR}/Contents/MacOS/${APP_NAME}" | awk '{print $1}')"
ARCHIVE_SHA="$(shasum -a 256 "${DIST_VERIFY_DIR}/${APP_NAME}.app/Contents/MacOS/${APP_NAME}" | awk '{print $1}')"
if [[ "${INSTALL_SHA}" != "${ARCHIVE_SHA}" ]]; then
  echo "Refusing to package: ZIP executable differs from installed Release." >&2
  exit 1
fi

# Only a fully notarized, stapled, Gatekeeper-accepted archive reaches dist.
mv -f "${FINAL_ZIP_PATH}" "${DIST_ZIP_PATH}"

echo "Installed ${INSTALL_APP_DIR}"
echo "Created notarized and stapled public artifact ${DIST_ZIP_PATH}"
echo "Run: open \"${INSTALL_APP_DIR}\""
