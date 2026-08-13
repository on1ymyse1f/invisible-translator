#!/usr/bin/env bash
set -euo pipefail

HOST_NAME="com.on1ymyse1f.InvisibleTranslator"
BROWSER="${1:-chrome}"

case "${BROWSER}" in
  chrome)
    MANIFEST="${HOME}/Library/Application Support/Google/Chrome/NativeMessagingHosts/${HOST_NAME}.json"
    ;;
  chromium)
    MANIFEST="${HOME}/Library/Application Support/Chromium/NativeMessagingHosts/${HOST_NAME}.json"
    ;;
  *)
    echo "Usage: $0 [chrome|chromium]" >&2
    exit 2
    ;;
esac

if [[ ! -e "${MANIFEST}" ]]; then
  echo "No native-host manifest is installed for ${BROWSER}."
  exit 0
fi
if [[ -L "${MANIFEST}" ]] || [[ "$(plutil -extract name raw "${MANIFEST}" 2>/dev/null || true)" != "${HOST_NAME}" ]]; then
  echo "Refusing to remove an unexpected or symlinked manifest." >&2
  exit 1
fi

/usr/bin/trash "${MANIFEST}"
echo "Moved the ${BROWSER} native-host manifest to Trash."
