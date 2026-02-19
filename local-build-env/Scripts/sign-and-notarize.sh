#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_BUILD_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${LOCAL_BUILD_ROOT}/.." && pwd)"

# shellcheck disable=SC1091
[[ -f "${LOCAL_BUILD_ROOT}/version.env.example" ]] && source "${LOCAL_BUILD_ROOT}/version.env.example"
# shellcheck disable=SC1091
[[ -f "${LOCAL_BUILD_ROOT}/version.env" ]] && source "${LOCAL_BUILD_ROOT}/version.env"
# shellcheck disable=SC1091
[[ -f "${LOCAL_BUILD_ROOT}/.env" ]] && source "${LOCAL_BUILD_ROOT}/.env"

APP_NAME="${APP_NAME:-VoiceInk}"
SCHEME="${SCHEME:-VoiceInk}"
PROJECT_PATH="${PROJECT_PATH:-${REPO_ROOT}/VoiceInk.xcodeproj}"
CONFIGURATION="${CONFIGURATION:-Release}"
ARCHS="${ARCHS:-arm64 x86_64}"
BUNDLE_ID="${BUNDLE_ID:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
CERT_P12_PATH="${CERT_P12_PATH:-${LOCAL_BUILD_ROOT}/cert.p12}"
EXPORT_DIR="${EXPORT_DIR:-${LOCAL_BUILD_ROOT}/dist}"
ENTITLEMENTS_PATH="${ENTITLEMENTS_PATH:-${REPO_ROOT}/VoiceInk/VoiceInk.local.entitlements}"
LAUNCH_APP_AFTER_BUILD="${LAUNCH_APP_AFTER_BUILD:-0}"

if [[ "${1:-}" == "--launch" ]]; then
  LAUNCH_APP_AFTER_BUILD=1
fi

ARCHIVE_DIR="${LOCAL_BUILD_ROOT}/build"
ARCHIVE_PATH="${ARCHIVE_DIR}/${APP_NAME}.xcarchive"
STAGING_DIR="${LOCAL_BUILD_ROOT}/staging"
APP_PATH="${STAGING_DIR}/${APP_NAME}.app"
DMG_PATH="${EXPORT_DIR}/${APP_NAME}.dmg"
DMG_STAGING="${LOCAL_BUILD_ROOT}/dmg-staging"
KEYCHAIN_NAME="voiceink-build-$(date +%s).keychain-db"
KEYCHAIN_PATH="${HOME}/Library/Keychains/${KEYCHAIN_NAME}"
KEYCHAIN_PASSWORD="$(openssl rand -base64 24)"

ORIGINAL_DEFAULT_KEYCHAIN="$(security default-keychain -d user | sed 's/[ "]//g')"
ORIGINAL_KEYCHAIN_LIST_RAW="$(security list-keychains -d user)"
ORIGINAL_KEYCHAIN_LIST=()
while IFS= read -r line; do
  clean="$(echo "$line" | sed 's/[ "]//g')"
  [[ -n "$clean" ]] && ORIGINAL_KEYCHAIN_LIST+=("$clean")
done <<< "${ORIGINAL_KEYCHAIN_LIST_RAW}"

log() { printf "%b%s%b\n" "${BLUE}" "$*" "${NC}"; }
ok() { printf "%b%s%b\n" "${GREEN}" "$*" "${NC}"; }
warn() { printf "%b%s%b\n" "${YELLOW}" "$*" "${NC}"; }
fail() { printf "%bERROR:%b %s\n" "${RED}" "${NC}" "$*" >&2; exit 1; }

cleanup() {
  set +e
  [[ -d "${DMG_STAGING}" ]] && rm -rf "${DMG_STAGING}"

  if [[ -n "${ORIGINAL_DEFAULT_KEYCHAIN}" ]]; then
    security default-keychain -d user -s "${ORIGINAL_DEFAULT_KEYCHAIN}" >/dev/null 2>&1
  fi
  if [[ ${#ORIGINAL_KEYCHAIN_LIST[@]} -gt 0 ]]; then
    security list-keychains -d user -s "${ORIGINAL_KEYCHAIN_LIST[@]}" >/dev/null 2>&1
  fi
  security delete-keychain "${KEYCHAIN_PATH}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

require_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required tool: $1"
}

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}${APP_NAME} Local Sign + Notarize Pipeline${NC}"
echo -e "${GREEN}========================================${NC}"

require_tool xcodebuild
require_tool codesign
require_tool hdiutil
require_tool xcrun
require_tool security
require_tool openssl

[[ -d "${PROJECT_PATH}" ]] || fail "Xcode project not found: ${PROJECT_PATH}"
[[ -f "${CERT_P12_PATH}" ]] || fail "Certificate not found: ${CERT_P12_PATH}"
[[ -f "${ENTITLEMENTS_PATH}" ]] || fail "Entitlements file not found: ${ENTITLEMENTS_PATH}"
[[ -n "${BUNDLE_ID}" ]] || fail "BUNDLE_ID is required (set in local-build-env/version.env or env)"
[[ -n "${APPLE_TEAM_ID}" ]] || fail "APPLE_TEAM_ID is required (set in local-build-env/version.env or env)"
[[ -n "${NOTARY_PROFILE}" ]] || fail "NOTARY_PROFILE is required (set in local-build-env/version.env or env)"

if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
  fail "Notary profile '${NOTARY_PROFILE}' is unavailable. Run: xcrun notarytool store-credentials ..."
fi

if [[ -z "${CERT_PASSWORD:-}" ]]; then
  if [[ -t 0 ]]; then
    printf "Enter password for %s: " "${CERT_P12_PATH}"
    read -r -s CERT_PASSWORD
    printf "\n"
  else
    fail "CERT_PASSWORD is required in non-interactive mode."
  fi
fi
[[ -n "${CERT_PASSWORD}" ]] || fail "Certificate password cannot be empty."

log "Creating temporary keychain"
security create-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"
security unlock-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"
security set-keychain-settings -lut 21600 "${KEYCHAIN_PATH}"

if ! security import "${CERT_P12_PATH}" \
  -k "${KEYCHAIN_PATH}" \
  -P "${CERT_PASSWORD}" \
  -T /usr/bin/codesign \
  -T /usr/bin/security >/dev/null 2>&1; then
  fail "Failed to import certificate from ${CERT_P12_PATH}. Check password/certificate validity."
fi
security set-key-partition-list -S apple-tool:,apple: -s -k "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}" >/dev/null

security list-keychains -d user -s "${KEYCHAIN_PATH}" "${ORIGINAL_KEYCHAIN_LIST[@]}"
security default-keychain -d user -s "${KEYCHAIN_PATH}"

IDENTITY_LINE="$(security find-identity -v -p codesigning "${KEYCHAIN_PATH}" | grep "Developer ID Application" | head -n 1 || true)"
[[ -n "${IDENTITY_LINE}" ]] || fail "No 'Developer ID Application' identity found in ${CERT_P12_PATH}. Notarization requires Developer ID."

IDENTITY_HASH="$(echo "${IDENTITY_LINE}" | awk '{print $2}')"
IDENTITY_NAME="$(echo "${IDENTITY_LINE}" | sed 's/.*"\(.*\)".*/\1/')"
ok "Using signing identity: ${IDENTITY_NAME}"

codesign_nested() {
  local target="$1"
  /usr/bin/codesign --force --timestamp --options runtime \
    --sign "${IDENTITY_HASH}" --keychain "${KEYCHAIN_PATH}" "$target"
}

codesign_runtime_app() {
  local app="$1"
  /usr/bin/codesign --force --timestamp --options runtime \
    --sign "${IDENTITY_HASH}" --keychain "${KEYCHAIN_PATH}" \
    --entitlements "${ENTITLEMENTS_PATH}" "$app"
}

is_macho_file() {
  local path="$1"
  local kind
  kind="$("/usr/bin/file" -b "$path" 2>/dev/null || true)"
  [[ "$kind" == *"Mach-O"* ]]
}

resign_staged_app() {
  local app="$1"
  local f
  local bundle

  # Sign all nested executables first (covers Sparkle helper binaries).
  while IFS= read -r -d '' f; do
    if is_macho_file "$f"; then
      codesign_nested "$f"
    fi
  done < <(/usr/bin/find "$app" -type f -perm -111 -print0)

  # Sign nested code bundles deepest-first.
  while IFS= read -r bundle; do
    # Sign root app only once at the end with entitlements.
    if [[ "$bundle" == "$app" ]]; then
      continue
    fi
    codesign_nested "$bundle"
  done < <(
    /usr/bin/find "$app" -type d \( -name "*.xpc" -o -name "*.appex" -o -name "*.framework" -o -name "*.app" \) \
      | /usr/bin/awk '{ print length, $0 }' \
      | /usr/bin/sort -rn \
      | /usr/bin/cut -d' ' -f2-
  )

  # Sign the app last with runtime + entitlements.
  codesign_runtime_app "$app"
}

require_hardened_runtime() {
  local target="$1"
  local details
  if ! details="$(/usr/bin/codesign -dvv "$target" 2>&1)"; then
    fail "Unable to inspect code signature on: $target"
  fi
  if ! /usr/bin/grep -q "flags=.*runtime" <<<"$details"; then
    fail "Hardened runtime is missing on: $target"
  fi
}

has_hardened_runtime() {
  local target="$1"
  local details
  details="$(/usr/bin/codesign -dvv "$target" 2>&1)" || return 1
  /usr/bin/grep -q "flags=.*runtime" <<<"$details"
}

repair_sparkle_runtime() {
  local app="$1"
  local sparkle_fw="$app/Contents/Frameworks/Sparkle.framework"
  local sparkle_root="$sparkle_fw/Versions/B"
  local autoupdate="$sparkle_root/Autoupdate"
  local updater_app="$sparkle_root/Updater.app"
  local updater_exec="$updater_app/Contents/MacOS/Updater"
  local downloader_xpc="$sparkle_root/XPCServices/Downloader.xpc"
  local downloader_exec="$downloader_xpc/Contents/MacOS/Downloader"
  local installer_xpc="$sparkle_root/XPCServices/Installer.xpc"
  local installer_exec="$installer_xpc/Contents/MacOS/Installer"
  local repaired=0

  [[ -e "$autoupdate" ]] && if ! has_hardened_runtime "$autoupdate"; then
    warn "Repairing hardened runtime on Sparkle Autoupdate"
    codesign_nested "$autoupdate"
    repaired=1
  fi

  [[ -e "$updater_exec" ]] && if ! has_hardened_runtime "$updater_exec"; then
    warn "Repairing hardened runtime on Sparkle Updater.app"
    codesign_nested "$updater_app"
    repaired=1
  fi

  [[ -e "$downloader_exec" ]] && if ! has_hardened_runtime "$downloader_exec"; then
    warn "Repairing hardened runtime on Sparkle Downloader.xpc"
    codesign_nested "$downloader_xpc"
    repaired=1
  fi

  [[ -e "$installer_exec" ]] && if ! has_hardened_runtime "$installer_exec"; then
    warn "Repairing hardened runtime on Sparkle Installer.xpc"
    codesign_nested "$installer_xpc"
    repaired=1
  fi

  if [[ "$repaired" -eq 1 ]]; then
    # Re-seal parent containers after nested repairs.
    codesign_nested "$sparkle_fw"
    codesign_runtime_app "$app"
  fi
}

verify_sparkle_runtime() {
  local app="$1"
  local path
  local sparkle_root="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
  local required=(
    "$sparkle_root/Autoupdate"
    "$sparkle_root/Updater.app/Contents/MacOS/Updater"
    "$sparkle_root/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
    "$sparkle_root/XPCServices/Installer.xpc/Contents/MacOS/Installer"
  )

  for path in "${required[@]}"; do
    [[ -e "$path" ]] || continue
    require_hardened_runtime "$path"
  done
}

log "Preparing build directories"
rm -rf "${ARCHIVE_PATH}" "${STAGING_DIR}" "${DMG_PATH}"
mkdir -p "${ARCHIVE_DIR}" "${STAGING_DIR}" "${EXPORT_DIR}"

log "Running xcodebuild archive (${CONFIGURATION}, ARCHS=${ARCHS})"
pushd "${REPO_ROOT}" >/dev/null
xcodebuild archive \
  -project "${PROJECT_PATH}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -archivePath "${ARCHIVE_PATH}" \
  -destination "generic/platform=macOS" \
  ARCHS="${ARCHS}" \
  ONLY_ACTIVE_ARCH=NO \
  PRODUCT_BUNDLE_IDENTIFIER="${BUNDLE_ID}" \
  DEVELOPMENT_TEAM="${APPLE_TEAM_ID}" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="${IDENTITY_NAME}" \
  CODE_SIGN_ENTITLEMENTS="${ENTITLEMENTS_PATH}" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) LOCAL_BUILD' \
  PROVISIONING_PROFILE_SPECIFIER= \
  OTHER_CODE_SIGN_FLAGS="--keychain ${KEYCHAIN_PATH}"
popd >/dev/null

ARCHIVED_APP="${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app"
[[ -d "${ARCHIVED_APP}" ]] || fail "Expected archived app was not found: ${ARCHIVED_APP}"
ditto "${ARCHIVED_APP}" "${APP_PATH}"
xattr -cr "${APP_PATH}"

log "Re-signing staged app and nested binaries for notarization"
resign_staged_app "${APP_PATH}"
repair_sparkle_runtime "${APP_PATH}"
verify_sparkle_runtime "${APP_PATH}"

log "Verifying app signature"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
if ! spctl --assess --type execute --verbose=4 "${APP_PATH}" >/dev/null 2>&1; then
  warn "Gatekeeper rejects pre-notarization app (expected for Developer ID before notarization)."
fi
ok "App signature verification passed"

log "Creating DMG"
rm -rf "${DMG_STAGING}"
mkdir -p "${DMG_STAGING}"
ditto "${APP_PATH}" "${DMG_STAGING}/${APP_NAME}.app"
ln -s /Applications "${DMG_STAGING}/Applications"
hdiutil create -volname "${APP_NAME}" -srcfolder "${DMG_STAGING}" -ov -format UDZO "${DMG_PATH}" >/dev/null

log "Signing DMG"
codesign --force --timestamp --sign "${IDENTITY_HASH}" --keychain "${KEYCHAIN_PATH}" "${DMG_PATH}"
codesign --verify --strict --verbose=2 "${DMG_PATH}"

log "Submitting DMG for notarization with profile '${NOTARY_PROFILE}'"
NOTARY_OUTPUT="$(xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait --output-format json)"
NOTARY_ID="$(printf "%s" "${NOTARY_OUTPUT}" | /usr/bin/plutil -extract id raw -o - - 2>/dev/null || true)"
NOTARY_STATUS="$(printf "%s" "${NOTARY_OUTPUT}" | /usr/bin/plutil -extract status raw -o - - 2>/dev/null || true)"

if [[ "${NOTARY_STATUS}" != "Accepted" ]]; then
  warn "Notarization status: ${NOTARY_STATUS:-unknown}"
  if [[ -n "${NOTARY_ID}" ]]; then
    warn "Fetching notarization log for submission ${NOTARY_ID}"
    xcrun notarytool log "${NOTARY_ID}" --keychain-profile "${NOTARY_PROFILE}" || true
  fi
  fail "Notarization failed; stapling skipped."
fi

log "Stapling notarization ticket"
xcrun stapler staple "${DMG_PATH}"
xcrun stapler staple "${APP_PATH}" >/dev/null || true

log "Final Gatekeeper assessment"
spctl --assess --type open --context context:primary-signature --verbose=4 "${DMG_PATH}"
ok "Notarized artifact is ready: ${DMG_PATH}"
ok "Signed app bundle: ${APP_PATH}"

if [[ "${LAUNCH_APP_AFTER_BUILD}" == "1" ]]; then
  log "Launching app for local runtime check"
  open "${APP_PATH}"
fi
