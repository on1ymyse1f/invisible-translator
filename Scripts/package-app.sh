#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ClaudePromptTranslator"
NATIVE_HOST_NAME="ClaudePromptTranslatorNativeHost"

# Establish artifact provenance before creating scratch directories or making
# any other filesystem changes. A rejected dirty checkout must be side-effect
# free, including leaving no orphaned mktemp directories behind.
if [[ -n "$(git -C "${ROOT_DIR}" status --porcelain --untracked-files=normal)" ]]; then
  echo "Refusing to package a dirty worktree; commit the exact reviewed source first so artifact provenance is truthful." >&2
  exit 2
fi

INSTALL_APP_DIR="${INSTALL_APP_DIR:-${HOME}/Applications/${APP_NAME}.app}"
DIST_DIR="${ROOT_DIR}/dist"
DIST_ZIP_PATH="${DIST_DIR}/${APP_NAME}.app.zip"
DIST_MANIFEST_PATH="${DIST_DIR}/${APP_NAME}.app.manifest.json"
LOCAL_DIST_DIR="${DIST_DIR}/local-test"
LOCAL_ZIP_PATH="${LOCAL_DIST_DIR}/${APP_NAME}.UNNOTARIZED.app.zip"
LOCAL_MANIFEST_PATH="${LOCAL_DIST_DIR}/${APP_NAME}.UNNOTARIZED.app.manifest.json"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${ROOT_DIR}/Packaging/Info.plist")"
STAGING_DIR=""
RELEASE_SCRATCH=""
RELEASE_DERIVED_DATA=""
APP_DIR=""
VERIFY_SCRIPT="${ROOT_DIR}/Scripts/verify-release-app.sh"
AUDIT_SCRIPT="${ROOT_DIR}/Scripts/audit-artifact.sh"
MANIFEST_SCRIPT="${ROOT_DIR}/Scripts/write-release-manifest.sh"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
ARTIFACT_TIER="${ARTIFACT_TIER:-core}"
PRIVATE_DSYM_ROOT="${PRIVATE_DSYM_ROOT:-${HOME}/Library/Application Support/ClaudePromptTranslator/PrivateDSYM}"
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

verify_dsym_matches_binary() {
  local binary_path="$1"
  local dsym_path="$2"
  local component_name="$3"
  local binary_uuids
  local dsym_uuids

  binary_uuids="$(
    xcrun dwarfdump --uuid "${binary_path}" \
      | /usr/bin/awk '$1 == "UUID:" { print $2 " " $3 }' \
      | /usr/bin/sort -u
  )"
  dsym_uuids="$(
    xcrun dwarfdump --uuid "${dsym_path}" \
      | /usr/bin/awk '$1 == "UUID:" { print $2 " " $3 }' \
      | /usr/bin/sort -u
  )"
  if [[ -z "${binary_uuids}" || "${binary_uuids}" != "${dsym_uuids}" ]]; then
    echo "Refusing to package: ${component_name} dSYM UUID does not match its unstripped Release binary." >&2
    exit 1
  fi
}

cleanup() {
  if [[ -n "${STAGING_DIR}" && -d "${STAGING_DIR}" ]]; then
    rm -rf -- "${STAGING_DIR}"
  fi
  if [[ -n "${RELEASE_SCRATCH}" && -d "${RELEASE_SCRATCH}" ]]; then
    rm -rf -- "${RELEASE_SCRATCH}"
  fi
  if [[ -n "${INSTALL_SWAP_DIR}" && -d "${INSTALL_SWAP_DIR}" \
        && "$(basename "${INSTALL_SWAP_DIR}")" == ".${APP_NAME}.install."* ]]; then
    # Never let an interrupted installer permanently delete the user's prior
    # app. Restore it if the destination is absent; otherwise move recoverable
    # app bundles to Trash and remove the empty transaction directory only.
    if [[ -d "${INSTALL_SWAP_DIR}/previous-${APP_NAME}.app" \
          && ! -e "${INSTALL_APP_DIR}" ]]; then
      mv "${INSTALL_SWAP_DIR}/previous-${APP_NAME}.app" "${INSTALL_APP_DIR}" || true
    fi
    for recoverable_app in \
      "${INSTALL_SWAP_DIR}/previous-${APP_NAME}.app" \
      "${INSTALL_SWAP_DIR}/failed-${APP_NAME}.app"; do
      if [[ -d "${recoverable_app}" ]]; then
        /usr/bin/trash "${recoverable_app}" || true
      fi
    done
    if [[ -d "${INSTALL_SWAP_DIR}/${APP_NAME}.app" ]]; then
      rm -rf -- "${INSTALL_SWAP_DIR}/${APP_NAME}.app"
    fi
    rmdir "${INSTALL_SWAP_DIR}" 2>/dev/null || \
      echo "Installer recovery directory retained: ${INSTALL_SWAP_DIR}" >&2
  fi
}
trap cleanup EXIT

# Arm the cleanup trap before either allocation. If the second mktemp fails,
# the first directory is still removed automatically.
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}.XXXXXX")"
RELEASE_SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}-release-build.XXXXXX")"
RELEASE_DERIVED_DATA="${RELEASE_SCRATCH}/DerivedData"
APP_DIR="${STAGING_DIR}/${APP_NAME}.app"

validate_install_destination "${INSTALL_APP_DIR}"

# The optional 0.9 runtime pulls dynamic frameworks and resources. Until the
# packaging path embeds and signs each nested component explicitly, fail closed
# instead of silently emitting an incomplete app that happens to compile.
if [[ "${CPT_INCLUDE_OPTIONAL_RUNTIME:-0}" == "1" ]]; then
  echo "Refusing to package CPT_INCLUDE_OPTIONAL_RUNTIME=1: optional framework/resource embedding is not implemented yet." >&2
  exit 2
fi
if [[ "${ARTIFACT_TIER}" != "core" ]]; then
  echo "Refusing ARTIFACT_TIER=${ARTIFACT_TIER}: the full framework/resource embedding path is not implemented." >&2
  exit 2
fi

cd "${ROOT_DIR}"

if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

# SpeechAnalyzer is runtime-gated to macOS 26+, while the app still runs its
# SFSpeechRecognizer path on macOS 15-25. The source nevertheless needs the
# macOS 26 SDK declarations at compile time, so reject an older release
# toolchain explicitly instead of surfacing an opaque Swift compiler failure.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
SDK_MAJOR="${SDK_VERSION%%.*}"
if [[ ! "${SDK_MAJOR}" =~ ^[0-9]+$ ]] || (( SDK_MAJOR < 26 )); then
  echo "Refusing to package: macOS SDK 26 or newer is required; found ${SDK_VERSION}." >&2
  exit 2
fi

"${ROOT_DIR}/Scripts/test.sh"
# A release must not rebuild the checkout's .build cache. The temporary
# scratch/DerivedData directories are removed after the signed artifact has
# been verified. SwiftPM uses --scratch-path; its Clang module cache is also
# explicitly contained for toolchains that invoke Clang while linking.
mkdir -p "${RELEASE_DERIVED_DATA}/ModuleCache.noindex"
export CLANG_MODULE_CACHE_PATH="${RELEASE_DERIVED_DATA}/ModuleCache.noindex"
swift build \
  --package-path "${ROOT_DIR}" \
  --scratch-path "${RELEASE_SCRATCH}" \
  --arch arm64 \
  -c release \
  -Xswiftc -g
RELEASE_BIN_DIR="$(swift build \
  --package-path "${ROOT_DIR}" \
  --scratch-path "${RELEASE_SCRATCH}" \
  --arch arm64 \
  -c release \
  -Xswiftc -g \
  --show-bin-path)"
EXECUTABLE_PATH="${RELEASE_BIN_DIR}/${APP_NAME}"
NATIVE_HOST_EXECUTABLE_PATH="${RELEASE_BIN_DIR}/${NATIVE_HOST_NAME}"
if [[ ! -x "${EXECUTABLE_PATH}" ]]; then
  echo "Release executable was not produced: ${EXECUTABLE_PATH}" >&2
  exit 1
fi
if [[ ! -x "${NATIVE_HOST_EXECUTABLE_PATH}" ]]; then
  echo "Release native-host executable was not produced: ${NATIVE_HOST_EXECUTABLE_PATH}" >&2
  exit 1
fi

# 1.0 is intentionally Apple Silicon only. Do this before copying, stripping
# or signing so an x86_64 or universal SwiftPM product can never become a
# release artifact by accident.
RELEASE_ARCHITECTURES="$(/usr/bin/lipo -archs "${EXECUTABLE_PATH}" 2>/dev/null || true)"
NATIVE_HOST_RELEASE_ARCHITECTURES="$(/usr/bin/lipo -archs "${NATIVE_HOST_EXECUTABLE_PATH}" 2>/dev/null || true)"
if [[ "${RELEASE_ARCHITECTURES}" != "arm64" \
      || "${NATIVE_HOST_RELEASE_ARCHITECTURES}" != "arm64" ]]; then
  echo "Refusing to package: main executable must be arm64-only; found ${RELEASE_ARCHITECTURES:-<unknown>}." >&2
  echo "Native-host architectures: ${NATIVE_HOST_RELEASE_ARCHITECTURES:-<unknown>}." >&2
  exit 1
fi

# Privacy regression guard: no debug-only process control or diagnostics entry
# point may enter production.
for DEBUG_MARKER in \
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
  'CPT_TEST_BROWSER_NATIVE_SOCKET'; do
  if /usr/bin/strings "${EXECUTABLE_PATH}" "${NATIVE_HOST_EXECUTABLE_PATH}" \
      | /usr/bin/grep -Fq -- "${DEBUG_MARKER}"; then
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
cp "${NATIVE_HOST_EXECUTABLE_PATH}" "${APP_DIR}/Contents/MacOS/${NATIVE_HOST_NAME}"
cp "${ROOT_DIR}/Packaging/Info.plist" "${APP_DIR}/Contents/Info.plist"
cp "${ROOT_DIR}/Resources/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"
chmod +x "${APP_DIR}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_DIR}/Contents/MacOS/${NATIVE_HOST_NAME}"
xattr -cr "${APP_DIR}" 2>/dev/null || true

# Archive symbols before stripping. The dSYM never enters the app, ZIP or
# repository. A timestamped directory prevents a later local build from
# replacing symbols needed to inspect an earlier crash report.
GIT_SHA="$(git -C "${ROOT_DIR}" rev-parse HEAD)"
DSYM_TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DSYM_STAGE="${STAGING_DIR}/${APP_NAME}.app.dSYM"
PRIVATE_DSYM_PATH="${PRIVATE_DSYM_ROOT}/${VERSION}-${GIT_SHA}-${DSYM_TIMESTAMP}/${APP_NAME}.app.dSYM"
NATIVE_HOST_DSYM_STAGE="${STAGING_DIR}/${NATIVE_HOST_NAME}.dSYM"
PRIVATE_NATIVE_HOST_DSYM_PATH="${PRIVATE_DSYM_ROOT}/${VERSION}-${GIT_SHA}-${DSYM_TIMESTAMP}/${NATIVE_HOST_NAME}.dSYM"
mkdir -p "$(dirname "${PRIVATE_DSYM_PATH}")"
xcrun dsymutil "${EXECUTABLE_PATH}" -o "${DSYM_STAGE}"
verify_dsym_matches_binary "${EXECUTABLE_PATH}" "${DSYM_STAGE}" "main executable"
ditto --norsrc --noextattr --noacl --noqtn "${DSYM_STAGE}" "${PRIVATE_DSYM_PATH}"
xcrun dsymutil "${NATIVE_HOST_EXECUTABLE_PATH}" -o "${NATIVE_HOST_DSYM_STAGE}"
verify_dsym_matches_binary \
  "${NATIVE_HOST_EXECUTABLE_PATH}" "${NATIVE_HOST_DSYM_STAGE}" "native host"
ditto --norsrc --noextattr --noacl --noqtn \
  "${NATIVE_HOST_DSYM_STAGE}" "${PRIVATE_NATIVE_HOST_DSYM_PATH}"
verify_dsym_matches_binary "${EXECUTABLE_PATH}" "${PRIVATE_DSYM_PATH}" "archived main executable"
verify_dsym_matches_binary \
  "${NATIVE_HOST_EXECUTABLE_PATH}" "${PRIVATE_NATIVE_HOST_DSYM_PATH}" "archived native host"

# Do not strip a signed Mach-O: it would invalidate the signature and risks
# accidentally publishing a bundle whose signature no longer represents its
# contents. SwiftPM output is intentionally unsigned; the staged copy is
# stripped before the first signing operation below.
STAGED_BINARY="${APP_DIR}/Contents/MacOS/${APP_NAME}"
STAGED_NATIVE_HOST="${APP_DIR}/Contents/MacOS/${NATIVE_HOST_NAME}"
if codesign --verify --strict "${STAGED_BINARY}" >/dev/null 2>&1; then
  echo "Refusing to strip an already signed staged executable." >&2
  exit 1
fi
xcrun strip -S -x "${STAGED_BINARY}"
if codesign --verify --strict "${STAGED_NATIVE_HOST}" >/dev/null 2>&1; then
  echo "Refusing to strip an already signed staged native host." >&2
  exit 1
fi
xcrun strip -S -x "${STAGED_NATIVE_HOST}"
"${AUDIT_SCRIPT}" --tier "${ARTIFACT_TIER}" "${APP_DIR}"

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
    codesign --force --timestamp --options runtime \
      --identifier local.codex.ClaudePromptTranslator.NativeHost \
      --sign "${SIGN_IDENTITY}" "${STAGED_NATIVE_HOST}" >/dev/null
    codesign --force --timestamp --options runtime --sign "${SIGN_IDENTITY}" "${APP_DIR}" >/dev/null
  else
    echo "Signing with an available local development identity."
    codesign --force --timestamp=none --options runtime \
      --identifier local.codex.ClaudePromptTranslator.NativeHost \
      --sign "${SIGN_IDENTITY}" "${STAGED_NATIVE_HOST}" >/dev/null
    codesign --force --timestamp=none --options runtime --sign "${SIGN_IDENTITY}" "${APP_DIR}" >/dev/null
  fi
else
  echo "Signing ad hoc; Accessibility permission may need to be re-granted after rebuilds."
  codesign --force --options runtime \
    --identifier local.codex.ClaudePromptTranslator.NativeHost \
    --sign - "${STAGED_NATIVE_HOST}" >/dev/null
  codesign --force --options runtime --sign - "${APP_DIR}" >/dev/null
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
  /usr/bin/trash "${PREVIOUS_INSTALL_APP}"
  echo "Moved the previous installed app to Trash for recoverable rollback."
fi
rmdir "${INSTALL_SWAP_DIR}"
INSTALL_SWAP_DIR=""

mkdir -p "${DIST_DIR}"

# Always create a clearly labelled local-test archive so size/integrity gates
# can be exercised without Developer ID or notary credentials. This archive is
# never presented as a public release.
LOCAL_STAGE_DIR="${STAGING_DIR}/local-dist-stage"
LOCAL_STAGE_APP="${LOCAL_STAGE_DIR}/${APP_NAME}.app"
LOCAL_FINAL_ZIP="${STAGING_DIR}/${APP_NAME}.UNNOTARIZED.app.zip"
LOCAL_FINAL_MANIFEST="${STAGING_DIR}/${APP_NAME}.UNNOTARIZED.app.manifest.json"
mkdir -p "${LOCAL_STAGE_DIR}" "${LOCAL_DIST_DIR}"
ditto --norsrc --noextattr --noacl --noqtn "${INSTALL_APP_DIR}" "${LOCAL_STAGE_APP}"
ditto -c -k --keepParent --norsrc --noextattr --noacl --noqtn \
  "${LOCAL_STAGE_APP}" \
  "${LOCAL_FINAL_ZIP}"
"${AUDIT_SCRIPT}" --tier "${ARTIFACT_TIER}" "${LOCAL_STAGE_APP}" "${LOCAL_FINAL_ZIP}"
"${MANIFEST_SCRIPT}" \
  "${LOCAL_STAGE_APP}" \
  "${LOCAL_FINAL_ZIP}" \
  "${LOCAL_FINAL_MANIFEST}" \
  local-test-unnotarized
mv -f "${LOCAL_FINAL_ZIP}" "${LOCAL_ZIP_PATH}"
mv -f "${LOCAL_FINAL_MANIFEST}" "${LOCAL_MANIFEST_PATH}"
echo "Created local-test artifact ${LOCAL_ZIP_PATH} (not notarized; not for public distribution)."

if [[ "${SIGN_IDENTITY}" != Developer\ ID\ Application:* || -z "${NOTARY_PROFILE}" ]]; then
  if [[ "${SIGN_IDENTITY}" != Developer\ ID\ Application:* ]]; then
    echo "Skipped public ZIP: Developer ID Application identity is unavailable."
  else
    echo "Skipped public ZIP: NOTARY_PROFILE is unavailable."
  fi
  echo "Existing dist artifacts were left untouched; they are not evidence that this local build is public-release ready."
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
"${VERIFY_SCRIPT}" --public --require-gatekeeper "${DIST_STAGE_APP}"

# Keep the locally installed Developer ID build equivalent to the public ZIP.
xcrun stapler staple "${INSTALL_APP_DIR}"
"${VERIFY_SCRIPT}" --public --require-gatekeeper "${INSTALL_APP_DIR}"

FINAL_ZIP_PATH="${STAGING_DIR}/${APP_NAME}.app.zip"
ditto -c -k --keepParent --norsrc --noextattr --noacl --noqtn \
  "${DIST_STAGE_APP}" \
  "${FINAL_ZIP_PATH}"

DIST_VERIFY_DIR="${STAGING_DIR}/dist-zip-verify"
mkdir -p "${DIST_VERIFY_DIR}"
ditto -x -k "${FINAL_ZIP_PATH}" "${DIST_VERIFY_DIR}"
"${VERIFY_SCRIPT}" --public --require-gatekeeper "${DIST_VERIFY_DIR}/${APP_NAME}.app"

INSTALL_SHA="$(shasum -a 256 "${INSTALL_APP_DIR}/Contents/MacOS/${APP_NAME}" | awk '{print $1}')"
ARCHIVE_SHA="$(shasum -a 256 "${DIST_VERIFY_DIR}/${APP_NAME}.app/Contents/MacOS/${APP_NAME}" | awk '{print $1}')"
INSTALL_NATIVE_HOST_SHA="$(shasum -a 256 "${INSTALL_APP_DIR}/Contents/MacOS/${NATIVE_HOST_NAME}" | awk '{print $1}')"
ARCHIVE_NATIVE_HOST_SHA="$(shasum -a 256 "${DIST_VERIFY_DIR}/${APP_NAME}.app/Contents/MacOS/${NATIVE_HOST_NAME}" | awk '{print $1}')"
if [[ "${INSTALL_SHA}" != "${ARCHIVE_SHA}" \
      || "${INSTALL_NATIVE_HOST_SHA}" != "${ARCHIVE_NATIVE_HOST_SHA}" ]]; then
  echo "Refusing to package: ZIP executable or native host differs from installed Release." >&2
  exit 1
fi

"${AUDIT_SCRIPT}" --tier "${ARTIFACT_TIER}" "${DIST_VERIFY_DIR}/${APP_NAME}.app" "${FINAL_ZIP_PATH}"
FINAL_MANIFEST_PATH="${STAGING_DIR}/${APP_NAME}.app.manifest.json"
"${MANIFEST_SCRIPT}" \
  "${DIST_VERIFY_DIR}/${APP_NAME}.app" \
  "${FINAL_ZIP_PATH}" \
  "${FINAL_MANIFEST_PATH}" \
  public-notarized

# Only a fully notarized, stapled, Gatekeeper-accepted archive reaches dist.
mv -f "${FINAL_ZIP_PATH}" "${DIST_ZIP_PATH}"
mv -f "${FINAL_MANIFEST_PATH}" "${DIST_MANIFEST_PATH}"

echo "Installed ${INSTALL_APP_DIR}"
echo "Created notarized and stapled public artifact ${DIST_ZIP_PATH}"
echo "Created release manifest ${DIST_MANIFEST_PATH}"
echo "Private dSYM archived at ${PRIVATE_DSYM_PATH}"
echo "Run: open \"${INSTALL_APP_DIR}\""
