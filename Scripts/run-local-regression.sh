#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT_DIR="${REPORT_DIR:-${ROOT_DIR}/review_artifacts}"
RUN_UI=0
RUN_INSTALL=0
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SCRATCH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ClaudePromptTranslator-regression.XXXXXX")"
STATUS_FILE="${SCRATCH_DIR}/status.tsv"
REPORT_MD="${REPORT_DIR}/regression-${STAMP}.md"
REPORT_JSON="${REPORT_DIR}/regression-${STAMP}.json"
HARNESS_PID=""
OVERALL_STATUS="PASS"

usage() {
  printf '%s\n' \
    "Usage: Scripts/run-local-regression.sh [--ui] [--install]" \
    "" \
    "  --ui       Run the offline ChatGPT composer/reply Accessibility E2E." \
    "  --install  Package, atomically install, explicitly launch, and verify the app." \
    "" \
    "All fixtures are synthetic. Reports contain only status, lengths, and hashes."
}

for argument in "$@"; do
  case "${argument}" in
    --ui) RUN_UI=1 ;;
    --install) RUN_INSTALL=1 ;;
    --help|-h) usage; exit 0 ;;
    *)
      echo "Unknown option: ${argument}" >&2
      usage >&2
      exit 2
      ;;
  esac
done

cleanup() {
  if [[ -n "${HARNESS_PID}" && "${HARNESS_PID}" =~ ^[0-9]+$ ]]; then
    kill "${HARNESS_PID}" 2>/dev/null || true
  fi
  if [[ -d "${SCRATCH_DIR}" \
        && "$(basename "${SCRATCH_DIR}")" == ClaudePromptTranslator-regression.* ]]; then
    rm -rf -- "${SCRATCH_DIR}"
  fi
}
trap cleanup EXIT

record() {
  local name="$1"
  local status="$2"
  local detail="$3"
  printf '%s\t%s\t%s\n' "${name}" "${status}" "${detail}" >> "${STATUS_FILE}"
  printf '%-30s %s  %s\n' "${name}" "${status}" "${detail}"
  if [[ "${status}" == "FAIL" ]]; then
    OVERALL_STATUS="FAIL"
  elif [[ "${status}" == "BLOCKED" && "${OVERALL_STATUS}" == "PASS" ]]; then
    OVERALL_STATUS="PARTIAL"
  fi
}

run_step() {
  local identifier="$1"
  local detail="$2"
  shift 2
  local log_path="${SCRATCH_DIR}/${identifier}.log"
  if "$@" >"${log_path}" 2>&1; then
    record "${identifier}" "PASS" "${detail}"
    return 0
  fi
  record "${identifier}" "FAIL" "${detail}; command failed"
  tail -n 40 "${log_path}" >&2 || true
  return 1
}

wait_for_file() {
  local path="$1"
  local timeout_seconds="$2"
  local attempt=0
  local max_attempts=$((timeout_seconds * 5))
  while [[ ! -s "${path}" && ${attempt} -lt ${max_attempts} ]]; do
    sleep 0.2
    attempt=$((attempt + 1))
  done
  [[ -s "${path}" ]]
}

screen_session_is_locked() {
  /usr/sbin/ioreg -n Root -d1 2>/dev/null \
    | /usr/bin/grep -q '"CGSSessionScreenIsLocked"=Yes'
}

field_value() {
  local key="$1"
  local path="$2"
  sed -n "s/^${key}=//p" "${path}" | tail -n 1
}

find_exact_app_pid() {
  local bundle_identifier="$1"
  local bundle_path="$2"
  /usr/bin/swift -e '
import AppKit
import Foundation

let identifier = CommandLine.arguments[1]
let expectedPath = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.path
let deadline = Date().addingTimeInterval(8)
repeat {
    let matches = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        .filter { $0.bundleURL?.standardizedFileURL.path == expectedPath }
    if let app = matches.max(by: { $0.processIdentifier < $1.processIdentifier }) {
        print(app.processIdentifier)
        exit(0)
    }
    Thread.sleep(forTimeInterval: 0.1)
} while Date() < deadline
exit(1)
' "${bundle_identifier}" "${bundle_path}"
}

terminate_exact_apps() {
  local bundle_identifier="$1"
  local bundle_path="$2"
  /usr/bin/swift -e '
import AppKit
import Foundation

let identifier = CommandLine.arguments[1]
let expectedPath = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.path
func matches() -> [NSRunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        .filter { $0.bundleURL?.standardizedFileURL.path == expectedPath }
}
for app in matches() { _ = app.terminate() }
let gracefulDeadline = Date().addingTimeInterval(3)
while Date() < gracefulDeadline && !matches().isEmpty {
    Thread.sleep(forTimeInterval: 0.1)
}
for app in matches() { _ = app.forceTerminate() }
let finalDeadline = Date().addingTimeInterval(2)
while Date() < finalDeadline && !matches().isEmpty {
    Thread.sleep(forTimeInterval: 0.1)
}
exit(matches().isEmpty ? 0 : 1)
' "${bundle_identifier}" "${bundle_path}"
}

run_self_test() {
  local debug_executable="$1"
  local operation="$2"
  local target_pid="$3"
  local output_path="$4"
  local log_path="$5"

  rm -f -- "${output_path}"
  "${debug_executable}" "--self-test-${operation}" "${target_pid}" \
    --self-test-output "${output_path}" >"${log_path}" 2>&1 &
  local self_test_pid=$!
  if ! wait_for_file "${output_path}" 50; then
    kill "${self_test_pid}" 2>/dev/null || true
    wait "${self_test_pid}" 2>/dev/null || true
    return 1
  fi
  wait "${self_test_pid}" 2>/dev/null || true
  return 0
}

run_set_input_self_test() {
  local debug_executable="$1"
  local target_pid="$2"
  local synthetic_text="$3"
  local output_path="$4"
  local log_path="$5"

  rm -f -- "${output_path}"
  "${debug_executable}" --self-test-set-input "${target_pid}" "${synthetic_text}" \
    --self-test-output "${output_path}" >"${log_path}" 2>&1 &
  local self_test_pid=$!
  if ! wait_for_file "${output_path}" 50; then
    kill "${self_test_pid}" 2>/dev/null || true
    wait "${self_test_pid}" 2>/dev/null || true
    return 1
  fi
  wait "${self_test_pid}" 2>/dev/null || true
  return 0
}

write_reports() {
  mkdir -p "${REPORT_DIR}"

  {
    printf '# 无感翻译本地回归报告\n\n'
    printf -- '- 时间（UTC）：`%s`\n' "${STAMP}"
    printf -- '- 总体状态：`%s`\n' "${OVERALL_STATUS}"
    printf -- '- 合成 UI 链路：`%s`\n' "$([[ ${RUN_UI} -eq 1 ]] && echo requested || echo not-requested)"
    printf -- '- 安装链路：`%s`\n' "$([[ ${RUN_INSTALL} -eq 1 ]] && echo requested || echo not-requested)"
    printf -- '- 隐私：报告不包含原文、译文、剪贴板内容、聊天记录或窗口标题。\n\n'
    printf '## 结果\n\n'
    printf '| 阶段 | 状态 | 说明 |\n| --- | --- | --- |\n'
    while IFS=$'\t' read -r name status detail; do
      printf '| %s | %s | %s |\n' "${name}" "${status}" "${detail}"
    done < "${STATUS_FILE}"
    printf '\n## 仍需人工验证\n\n'
    printf -- '- 首次辅助功能权限与 Apple 语言包下载确认。\n'
    printf -- '- TextEdit 精确选区替换及 Command+Z 撤销。\n'
    printf -- '- 真实 ChatGPT 冒烟测试只使用合成草稿，不能发送。\n'
    printf -- '- 双窗口切换、多显示器、PDF/Canvas/字幕区域 OCR 与屏幕边角。\n'
    printf -- '- Developer ID、公证与 Gatekeeper 公开发行门。\n'
  } > "${REPORT_MD}"

  {
    printf '{\n'
    printf '  "timestamp_utc": "%s",\n' "${STAMP}"
    printf '  "overall_status": "%s",\n' "${OVERALL_STATUS}"
    printf '  "synthetic_ui_requested": %s,\n' "$([[ ${RUN_UI} -eq 1 ]] && echo true || echo false)"
    printf '  "install_requested": %s,\n' "$([[ ${RUN_INSTALL} -eq 1 ]] && echo true || echo false)"
    printf '  "contains_raw_text": false,\n'
    printf '  "results": [\n'
    local first=1
    while IFS=$'\t' read -r name status detail; do
      local escaped_detail
      escaped_detail="$(printf '%s' "${detail}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
      if [[ ${first} -eq 0 ]]; then printf ',\n'; fi
      first=0
      printf '    {"stage":"%s","status":"%s","detail":"%s"}' \
        "${name}" "${status}" "${escaped_detail}"
    done < "${STATUS_FILE}"
    printf '\n  ]\n}\n'
  } > "${REPORT_JSON}"

  chmod 600 "${REPORT_MD}" "${REPORT_JSON}"
  printf 'Markdown report: %s\n' "${REPORT_MD}"
  printf 'JSON report: %s\n' "${REPORT_JSON}"
}

mkdir -p "${REPORT_DIR}"
: > "${STATUS_FILE}"

MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [[ "${MACOS_MAJOR}" =~ ^[0-9]+$ ]] && (( MACOS_MAJOR >= 15 )); then
  record "preflight-macos" "PASS" "macOS 15 or newer"
else
  record "preflight-macos" "FAIL" "requires macOS 15 or newer"
fi

for required_tool in swift xcodebuild xcrun plutil codesign; do
  if command -v "${required_tool}" >/dev/null 2>&1; then
    record "tool-${required_tool}" "PASS" "available"
  else
    record "tool-${required_tool}" "FAIL" "missing"
  fi
done

if find "${ROOT_DIR}/Scripts" "${ROOT_DIR}/TestHarness" -type f -name '*.sh' \
    -exec bash -n {} +; then
  record "shell-syntax" "PASS" "all shell scripts parse"
else
  record "shell-syntax" "FAIL" "one or more shell scripts do not parse"
fi

if plutil -lint \
    "${ROOT_DIR}/Packaging/Info.plist" \
    "${ROOT_DIR}/TestHarness/AIResponseHarness-Info.plist" \
    "${ROOT_DIR}/TestHarness/PasteCapture-Info.plist" >/dev/null; then
  record "plist-lint" "PASS" "all app and harness property lists parse"
else
  record "plist-lint" "FAIL" "property list validation failed"
fi

run_step "unit-tests" "isolated Swift tests with coverage" \
  "${ROOT_DIR}/Scripts/test.sh"

run_step "swift-release" "isolated SwiftPM Release build" \
  swift build --package-path "${ROOT_DIR}" \
    --scratch-path "${SCRATCH_DIR}/swift-release" -c release

if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
elif [[ -d "/Applications/Xcode-beta.app/Contents/Developer" ]]; then
  XCODE_DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
else
  XCODE_DEVELOPER_DIR="$(xcode-select -p)"
fi

run_step "xcode-release" "clean Xcode Release build without coverage injection" \
  env DEVELOPER_DIR="${XCODE_DEVELOPER_DIR}" xcodebuild \
    -project "${ROOT_DIR}/ClaudePromptTranslator.xcodeproj" \
    -scheme ClaudePromptTranslator \
    -configuration Release \
    -derivedDataPath "${SCRATCH_DIR}/xcode-release" \
    CODE_SIGNING_ALLOWED=NO \
    ENABLE_CODE_COVERAGE=NO \
    CLANG_COVERAGE_MAPPING=NO \
    clean build

BUILT_HARNESS_APP="${SCRATCH_DIR}/built-harness/ChatGPTSyntheticHarness.app"
run_step "synthetic-harness-build" "offline ChatGPT composer and reply fixture" \
  env TARGET_APP="${BUILT_HARNESS_APP}" \
    "${ROOT_DIR}/TestHarness/build-ai-response-harness.sh"

if [[ ${RUN_INSTALL} -eq 1 ]]; then
  run_step "package-install" "tests, signs, atomically installs, and verifies local app" \
    env DEVELOPER_DIR="${XCODE_DEVELOPER_DIR}" "${ROOT_DIR}/Scripts/package-app.sh"

  INSTALLED_APP="${HOME}/Applications/ClaudePromptTranslator.app"
  open "${INSTALLED_APP}"
  if INSTALLED_PID="$(find_exact_app_pid local.codex.ClaudePromptTranslator "${INSTALLED_APP}")"; then
    record "installed-launch" "PASS" "running PID resolved by bundle id and exact bundle path"
    if [[ -x /usr/sbin/lsof ]] \
        && /usr/sbin/lsof -nP -a -p "${INSTALLED_PID}" -iTCP -iUDP 2>/dev/null \
          | tail -n +2 | grep -q .; then
      record "runtime-network" "FAIL" "installed process has an open network socket"
    else
      record "runtime-network" "PASS" "no TCP or UDP socket observed in the snapshot"
    fi
  else
    record "installed-launch" "FAIL" "could not resolve the installed app by exact bundle path"
  fi
else
  INSTALLED_APP="${HOME}/Applications/ClaudePromptTranslator.app"
  if [[ -d "${INSTALLED_APP}" ]] \
      && "${ROOT_DIR}/Scripts/verify-release-app.sh" "${INSTALLED_APP}" \
        >"${SCRATCH_DIR}/installed-verify.log" 2>&1; then
    record "installed-app-verify" "PASS" "existing installed app passes signature/privacy checks"
  else
    record "installed-app-verify" "BLOCKED" "not installed in the default path or verification failed"
  fi
fi

if [[ ${RUN_UI} -eq 1 ]]; then
  if env DEVELOPER_DIR="${XCODE_DEVELOPER_DIR}" xcodebuild \
      -project "${ROOT_DIR}/ClaudePromptTranslator.xcodeproj" \
      -scheme ClaudePromptTranslator \
      -configuration Debug \
      -derivedDataPath "${SCRATCH_DIR}/xcode-debug" \
      build >"${SCRATCH_DIR}/xcode-debug.log" 2>&1; then
    record "xcode-debug" "PASS" "debug self-test app built in isolated DerivedData"
  else
    record "xcode-debug" "FAIL" "debug self-test app failed to build"
  fi

  DEBUG_APP="${SCRATCH_DIR}/xcode-debug/Build/Products/Debug/ClaudePromptTranslator.app"
  DEBUG_EXECUTABLE="${DEBUG_APP}/Contents/MacOS/ClaudePromptTranslator"
  LOCAL_SIGN_IDENTITY="$(
    security find-identity -p codesigning -v 2>/dev/null \
      | awk -F '"' '
          /Apple Development|Mac Developer/ { print $2; exit }
        '
  )"
  if [[ -d "${DEBUG_APP}" && -n "${LOCAL_SIGN_IDENTITY}" ]] \
      && xattr -cr "${DEBUG_APP}" \
      && codesign --force --deep --timestamp=none --options runtime \
        --sign "${LOCAL_SIGN_IDENTITY}" "${DEBUG_APP}" >/dev/null \
      && codesign --verify --deep --strict "${DEBUG_APP}"; then
    record "xcode-debug-sign" "PASS" "debug self-test uses the same stable local development identity as the installed app"
  elif [[ -d "${DEBUG_APP}" ]]; then
    record "xcode-debug-sign" "BLOCKED" "stable local development identity unavailable; TCC may require a separate grant"
  fi

  HARNESS_SOURCE_APP="${BUILT_HARNESS_APP}"
  HARNESS_APP="${SCRATCH_DIR}/ChatGPTSyntheticHarness.app"
  if ditto --norsrc --noextattr --noacl --noqtn \
      "${HARNESS_SOURCE_APP}" "${HARNESS_APP}" \
      && codesign --verify --deep --strict "${HARNESS_APP}"; then
    record "synthetic-harness-stage" "PASS" "isolated signed fixture copied to a unique private path"
  else
    record "synthetic-harness-stage" "FAIL" "could not stage the offline fixture"
  fi

  terminate_exact_apps local.codex.ChatGPTSyntheticHarness "${HARNESS_APP}" || true
  open -na "${HARNESS_APP}"
  if HARNESS_PID="$(find_exact_app_pid local.codex.ChatGPTSyntheticHarness "${HARNESS_APP}")"; then
    record "synthetic-harness-launch" "PASS" "resolved by bundle id and exact bundle path"
  else
    HARNESS_PID=""
    record "synthetic-harness-launch" "FAIL" "offline harness did not launch"
  fi

  if [[ -n "${HARNESS_PID}" && -x "${DEBUG_EXECUTABLE}" ]]; then
    CLIPBOARD_BEFORE="$(/usr/bin/swift -e 'import AppKit; print(NSPasteboard.general.changeCount)')"
    SYNTHETIC_DRAFT="请把这段合成草稿翻译成英文，只用于本地回归测试，不要发送。"
    SYNTHETIC_REPLACEMENT="This synthetic draft verifies a direct Accessibility replacement without sending."
    SYNTHETIC_DRAFT_HASH="$(printf '%s' "${SYNTHETIC_DRAFT}" | shasum -a 256 | awk '{print $1}')"
    SYNTHETIC_REPLACEMENT_HASH="$(printf '%s' "${SYNTHETIC_REPLACEMENT}" | shasum -a 256 | awk '{print $1}')"

    HARNESS_READY=0
    READY_ERROR_CODE=""
    for readiness_attempt in 1 2 3 4 5; do
      READY_RESULT="${SCRATCH_DIR}/ready-${readiness_attempt}.txt"
      if run_self_test "${DEBUG_EXECUTABLE}" inspect-input "${HARNESS_PID}" \
          "${READY_RESULT}" "${SCRATCH_DIR}/ready-${readiness_attempt}.log"; then
        READY_STATUS="$(field_value result "${READY_RESULT}")"
        READY_SOURCE_HASH="$(field_value source_sha256 "${READY_RESULT}")"
        READY_TRANSLATABLE="$(field_value translatable "${READY_RESULT}")"
        READY_WINDOW="$(field_value window_identity_stable "${READY_RESULT}")"
        READY_ERROR_CODE="$(field_value error_code "${READY_RESULT}")"
        if [[ "${READY_STATUS}" == "ok" \
              && "${READY_SOURCE_HASH}" == "${SYNTHETIC_DRAFT_HASH}" \
              && "${READY_TRANSLATABLE}" == "true" \
              && "${READY_WINDOW}" == "true" ]]; then
          HARNESS_READY=1
          break
        fi
        if [[ "${READY_ERROR_CODE}" == "accessibility_permission_required" ]]; then
          break
        fi
      fi
      sleep 0.35
    done

    if [[ ${HARNESS_READY} -eq 1 ]]; then
      record "synthetic-harness-ready" "PASS" "strict focused composer hash and window identity matched"
    elif screen_session_is_locked; then
      record "synthetic-harness-ready" "BLOCKED" "desktop session is locked; Accessibility UI inspection is unavailable"
    elif [[ "${READY_ERROR_CODE}" == "accessibility_permission_required" ]]; then
      record "synthetic-harness-ready" "BLOCKED" "debug self-test identity lacks Accessibility permission"
    else
      record "synthetic-harness-ready" "FAIL" "fixture window did not expose the expected strict composer before timeout"
    fi

    SELECTION_RESULT="${SCRATCH_DIR}/selection-result.txt"
    if [[ ${HARNESS_READY} -eq 1 ]] \
        && run_self_test "${DEBUG_EXECUTABLE}" selection "${HARNESS_PID}" \
        "${SELECTION_RESULT}" "${SCRATCH_DIR}/selection-self-test.log"; then
      SELECTION_STATUS="$(field_value result "${SELECTION_RESULT}")"
      SELECTION_SOURCE_HASH="$(field_value source_sha256 "${SELECTION_RESULT}")"
      SELECTION_METHOD="$(field_value capture_method "${SELECTION_RESULT}")"
      SELECTION_CLIPBOARD="$(field_value clipboard_unchanged "${SELECTION_RESULT}")"
      SELECTION_OCR="$(field_value ocr_used "${SELECTION_RESULT}")"
      SELECTION_ERROR_CODE="$(field_value error_code "${SELECTION_RESULT}")"
      if [[ "${SELECTION_STATUS}" == "ok" \
            && "${SELECTION_SOURCE_HASH}" == "${SYNTHETIC_DRAFT_HASH}" \
            && "${SELECTION_METHOD}" == "accessibility" \
            && "${SELECTION_CLIPBOARD}" == "true" \
            && "${SELECTION_OCR}" == "false" ]]; then
        record "synthetic-selection-e2e" "PASS" "selected draft captured through Accessibility; clipboard unchanged; OCR disabled; raw text omitted"
      elif [[ "${SELECTION_ERROR_CODE}" == "accessibility_permission_required" ]]; then
        record "synthetic-selection-e2e" "BLOCKED" "debug build lacks Accessibility permission"
      else
        record "synthetic-selection-e2e" "FAIL" "selection capture, hash, clipboard, or OCR assertion failed"
      fi
    elif [[ ${HARNESS_READY} -eq 0 ]]; then
      record "synthetic-selection-e2e" "BLOCKED" "strict composer readiness gate did not pass"
    else
      record "synthetic-selection-e2e" "FAIL" "selection self-test timed out"
    fi

    AX_INPUT_OK=0
    if [[ ${HARNESS_READY} -eq 1 ]]; then
      SET_RESULT="${SCRATCH_DIR}/set-input-result.txt"
      VERIFY_SET_RESULT="${SCRATCH_DIR}/verify-set-input-result.txt"
      if run_set_input_self_test "${DEBUG_EXECUTABLE}" "${HARNESS_PID}" \
          "${SYNTHETIC_REPLACEMENT}" "${SET_RESULT}" "${SCRATCH_DIR}/set-input.log" \
          && run_self_test "${DEBUG_EXECUTABLE}" inspect-input "${HARNESS_PID}" \
            "${VERIFY_SET_RESULT}" "${SCRATCH_DIR}/verify-set-input.log"; then
        SET_STATUS="$(field_value result "${SET_RESULT}")"
        SET_OUTPUT_HASH="$(field_value output_sha256 "${SET_RESULT}")"
        VERIFY_SET_STATUS="$(field_value result "${VERIFY_SET_RESULT}")"
        VERIFY_SET_HASH="$(field_value text_sha256 "${VERIFY_SET_RESULT}")"
        if [[ "${SET_STATUS}" == "ok" \
              && "${VERIFY_SET_STATUS}" == "ok" \
              && "${SET_OUTPUT_HASH}" == "${SYNTHETIC_REPLACEMENT_HASH}" \
              && "${VERIFY_SET_HASH}" == "${SYNTHETIC_REPLACEMENT_HASH}" ]]; then
          AX_INPUT_OK=1
          record "synthetic-input-ax-e2e" "PASS" "strict composer read and verified direct write succeeded; no Send control exists"
        else
          record "synthetic-input-ax-e2e" "FAIL" "direct AX write or hash verification failed"
        fi
      else
        record "synthetic-input-ax-e2e" "FAIL" "direct AX self-test timed out"
      fi
    else
      record "synthetic-input-ax-e2e" "BLOCKED" "strict composer readiness gate did not pass"
    fi

    RESET_OK=0
    if [[ ${AX_INPUT_OK} -eq 1 ]]; then
      RESET_RESULT="${SCRATCH_DIR}/reset-input-result.txt"
      if run_set_input_self_test "${DEBUG_EXECUTABLE}" "${HARNESS_PID}" \
          "${SYNTHETIC_DRAFT}" "${RESET_RESULT}" "${SCRATCH_DIR}/reset-input.log" \
          && [[ "$(field_value result "${RESET_RESULT}")" == "ok" ]] \
          && [[ "$(field_value output_sha256 "${RESET_RESULT}")" == "${SYNTHETIC_DRAFT_HASH}" ]]; then
        RESET_OK=1
      fi
    fi

    INLINE_RESULT="${SCRATCH_DIR}/inline-result.txt"
    if [[ ${RESET_OK} -eq 1 ]] \
        && run_self_test "${DEBUG_EXECUTABLE}" inline "${HARNESS_PID}" \
          "${INLINE_RESULT}" "${SCRATCH_DIR}/inline-self-test.log"; then
      INLINE_STATUS="$(field_value result "${INLINE_RESULT}")"
      INLINE_SOURCE_HASH="$(field_value source_sha256 "${INLINE_RESULT}")"
      INLINE_OUTPUT_HASH="$(field_value output_sha256 "${INLINE_RESULT}")"
      INLINE_SENT="$(field_value message_sent "${INLINE_RESULT}")"
      INLINE_ERROR_CODE="$(field_value error_code "${INLINE_RESULT}")"
      if [[ "${INLINE_STATUS}" == "ok" \
            && "${INLINE_SOURCE_HASH}" == "${SYNTHETIC_DRAFT_HASH}" \
            && -n "${INLINE_OUTPUT_HASH}" \
            && "${INLINE_SOURCE_HASH}" != "${INLINE_OUTPUT_HASH}" \
            && "${INLINE_SENT}" == "false" ]]; then
        record "apple-input-translation-runtime" "PASS" "Apple local translation replaced the draft; message_sent=false; raw text omitted"
      elif [[ "${INLINE_ERROR_CODE}" == "language_pair_not_installed" ]]; then
        record "apple-input-translation-runtime" "BLOCKED" "Apple on-device language pair was not ready after the bounded local preparation path"
      elif [[ "${INLINE_ERROR_CODE}" == "accessibility_permission_required" ]]; then
        record "apple-input-translation-runtime" "BLOCKED" "debug self-test identity lacks Accessibility permission"
      else
        record "apple-input-translation-runtime" "FAIL" "translation, replacement, or privacy assertion failed"
      fi
    elif [[ ${HARNESS_READY} -eq 0 ]]; then
      record "apple-input-translation-runtime" "BLOCKED" "strict composer readiness gate did not pass"
    else
      record "apple-input-translation-runtime" "FAIL" "could not restore the synthetic source before translation"
    fi

    SELECTED_RESPONSE_RESULT="${SCRATCH_DIR}/selected-response-result.txt"
    if [[ ${HARNESS_READY} -eq 1 ]] \
        && run_self_test "${DEBUG_EXECUTABLE}" selected-response "${HARNESS_PID}" \
        "${SELECTED_RESPONSE_RESULT}" "${SCRATCH_DIR}/selected-response-self-test.log"; then
      SELECTED_RESPONSE_STATUS="$(field_value result "${SELECTED_RESPONSE_RESULT}")"
      SELECTED_RESPONSE_SOURCE="$(field_value capture_source "${SELECTED_RESPONSE_RESULT}")"
      SELECTED_RESPONSE_PREFERRED="$(field_value selection_preferred "${SELECTED_RESPONSE_RESULT}")"
      SELECTED_RESPONSE_CLIPBOARD="$(field_value clipboard_unchanged "${SELECTED_RESPONSE_RESULT}")"
      SELECTED_RESPONSE_OCR="$(field_value ocr_used "${SELECTED_RESPONSE_RESULT}")"
      SELECTED_RESPONSE_ERROR_CODE="$(field_value error_code "${SELECTED_RESPONSE_RESULT}")"
      if [[ "${SELECTED_RESPONSE_STATUS}" == "ok" \
            && "${SELECTED_RESPONSE_SOURCE}" == "selectedText" \
            && "${SELECTED_RESPONSE_PREFERRED}" == "true" \
            && "${SELECTED_RESPONSE_CLIPBOARD}" == "true" \
            && "${SELECTED_RESPONSE_OCR}" == "false" ]]; then
        record "synthetic-selected-reply-e2e" "PASS" "selected assistant substring won over the complete latest reply; clipboard unchanged; OCR disabled"
      elif [[ "${SELECTED_RESPONSE_ERROR_CODE}" == "accessibility_permission_required" ]]; then
        record "synthetic-selected-reply-e2e" "BLOCKED" "debug build lacks Accessibility permission"
      else
        record "synthetic-selected-reply-e2e" "FAIL" "selected reply assertion failed; result=${SELECTED_RESPONSE_STATUS:-missing}; source=${SELECTED_RESPONSE_SOURCE:-missing}; preferred=${SELECTED_RESPONSE_PREFERRED:-missing}; clipboard=${SELECTED_RESPONSE_CLIPBOARD:-missing}; ocr=${SELECTED_RESPONSE_OCR:-missing}; error=${SELECTED_RESPONSE_ERROR_CODE:-none}"
      fi
    elif [[ ${HARNESS_READY} -eq 0 ]]; then
      record "synthetic-selected-reply-e2e" "BLOCKED" "strict fixture readiness gate did not pass"
    else
      record "synthetic-selected-reply-e2e" "FAIL" "selected reply self-test timed out"
    fi

    RESPONSE_RESULT="${SCRATCH_DIR}/response-result.txt"
    if [[ ${HARNESS_READY} -eq 1 ]] \
        && run_self_test "${DEBUG_EXECUTABLE}" response "${HARNESS_PID}" \
        "${RESPONSE_RESULT}" "${SCRATCH_DIR}/response-self-test.log"; then
      RESPONSE_STATUS="$(field_value result "${RESPONSE_RESULT}")"
      RESPONSE_SOURCE="$(field_value capture_source "${RESPONSE_RESULT}")"
      RESPONSE_OCR="$(field_value ocr_allowed "${RESPONSE_RESULT}")"
      RESPONSE_ERROR_CODE="$(field_value error_code "${RESPONSE_RESULT}")"
      if [[ "${RESPONSE_STATUS}" == "ok" \
            && "${RESPONSE_SOURCE}" != "opticalCharacterRecognition" \
            && "${RESPONSE_OCR}" == "false" ]]; then
        record "synthetic-reply-e2e" "PASS" "assistant reply selected via Accessibility; OCR disabled; raw text omitted"
      elif [[ "${RESPONSE_ERROR_CODE}" == "accessibility_permission_required" ]]; then
        record "synthetic-reply-e2e" "BLOCKED" "debug build lacks Accessibility permission"
      else
        record "synthetic-reply-e2e" "FAIL" "reply selection or privacy assertion failed"
      fi
    elif [[ ${HARNESS_READY} -eq 0 ]]; then
      record "synthetic-reply-e2e" "BLOCKED" "strict fixture readiness gate did not pass"
    else
      record "synthetic-reply-e2e" "FAIL" "self-test timed out"
    fi
    CLIPBOARD_AFTER="$(/usr/bin/swift -e 'import AppKit; print(NSPasteboard.general.changeCount)')"
    if [[ "${CLIPBOARD_BEFORE}" == "${CLIPBOARD_AFTER}" ]]; then
      record "ui-clipboard" "PASS" "synthetic AX path did not change the pasteboard"
    else
      record "ui-clipboard" "FAIL" "pasteboard change count changed during synthetic AX tests"
    fi
  else
    record "synthetic-harness-ready" "BLOCKED" "debug executable or isolated fixture process unavailable"
    record "synthetic-selection-e2e" "BLOCKED" "debug executable or isolated fixture process unavailable"
    record "synthetic-input-ax-e2e" "BLOCKED" "debug executable or isolated fixture process unavailable"
    record "apple-input-translation-runtime" "BLOCKED" "debug executable or isolated fixture process unavailable"
    record "synthetic-selected-reply-e2e" "BLOCKED" "debug executable or isolated fixture process unavailable"
    record "synthetic-reply-e2e" "BLOCKED" "debug executable or isolated fixture process unavailable"
  fi
else
  record "synthetic-ui-e2e" "BLOCKED" "not requested; rerun with --ui after granting Accessibility"
fi

write_reports

if [[ "${OVERALL_STATUS}" == "FAIL" ]]; then
  exit 1
fi
