#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_BASE="${REPO_ROOT}/.tmp/release-check"
STATE_FILE="${STATE_FILE:-${REPO_ROOT}/.github/codex-release-state.env}"
HISTORY_FILE="${HISTORY_FILE:-${REPO_ROOT}/docs/release-checks/history.tsv}"
SOURCE_DMG_URL="${SOURCE_DMG_URL:-https://persistent.oaistatic.com/codex-app-prod/Codex.dmg}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-MisonL/Codex-Mac-Intel-Converter-Sh}"
TARGET_ARCH_LABEL="x64"
RUN_AT_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
RELEASE_DATE="$(date +%Y%m%d)"
WORK_DIR="${TMP_BASE}/${RELEASE_DATE}_$(date +%H%M%S)"
DOWNLOADED_DMG="${WORK_DIR}/Codex.dmg"
MOUNT_POINT="${WORK_DIR}/mount"

LAST_SEEN_VERSION=""
LAST_SEEN_SHA256=""
LAST_RELEASE_TAG=""
LAST_CHECKED_AT_UTC=""
LAST_ACTION=""
ATTACHED_BY_SCRIPT=0

emit_output() {
  local key="$1"
  local value="$2"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "${key}" "${value}" >> "${GITHUB_OUTPUT}"
  fi
}

ensure_tracking_files() {
  mkdir -p "$(dirname "${STATE_FILE}")" "$(dirname "${HISTORY_FILE}")" "${TMP_BASE}"

  if [[ ! -f "${STATE_FILE}" ]]; then
    cat > "${STATE_FILE}" <<'EOF'
LAST_SEEN_VERSION=
LAST_SEEN_SHA256=
LAST_RELEASE_TAG=
LAST_CHECKED_AT_UTC=
LAST_ACTION=
EOF
  fi

  if [[ ! -f "${HISTORY_FILE}" ]]; then
    printf 'checked_at_utc\tsource_version\tsource_sha256\taction\trelease_tag\tnote\n' > "${HISTORY_FILE}"
  fi
}

load_state() {
  # shellcheck disable=SC1090
  source "${STATE_FILE}"
}

persist_state() {
  local version="$1"
  local sha256="$2"
  local release_tag="$3"
  local action="$4"

  cat > "${STATE_FILE}" <<EOF
LAST_SEEN_VERSION=${version}
LAST_SEEN_SHA256=${sha256}
LAST_RELEASE_TAG=${release_tag}
LAST_CHECKED_AT_UTC=${RUN_AT_UTC}
LAST_ACTION=${action}
EOF
}

append_history() {
  local version="$1"
  local sha256="$2"
  local action="$3"
  local release_tag="$4"
  local note="$5"

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${RUN_AT_UTC}" "${version}" "${sha256}" "${action}" "${release_tag}" "${note}" >> "${HISTORY_FILE}"
}

cleanup() {
  if [[ "${ATTACHED_BY_SCRIPT}" -eq 1 && -d "${MOUNT_POINT}" ]]; then
    hdiutil detach "${MOUNT_POINT}" >/dev/null 2>&1 || hdiutil detach -force "${MOUNT_POINT}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

download_source_dmg() {
  mkdir -p "${WORK_DIR}" "${MOUNT_POINT}"
  curl --fail --location --silent --show-error "${SOURCE_DMG_URL}" --output "${DOWNLOADED_DMG}"
  shasum -a 256 "${DOWNLOADED_DMG}" | awk '{print $1}'
}

read_source_version() {
  local info_plist=""
  local version=""

  hdiutil attach -readonly -nobrowse -mountpoint "${MOUNT_POINT}" "${DOWNLOADED_DMG}" >/dev/null
  ATTACHED_BY_SCRIPT=1
  info_plist="${MOUNT_POINT}/Codex.app/Contents/Info.plist"
  [[ -f "${info_plist}" ]] || return 1
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${info_plist}" 2>/dev/null || true)"
  if [[ -z "${version}" ]]; then
    version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${info_plist}" 2>/dev/null || true)"
  fi
  [[ -n "${version}" ]] || return 1
  printf '%s\n' "${version}"
}

find_existing_release_for_version() {
  local version="$1"

  gh api "repos/${GITHUB_REPOSITORY}/releases?per_page=100" | python3 -c '
import json
import sys

version = sys.argv[1]
prefix = f"v{version}-x64-"
for release in json.load(sys.stdin):
    tag = release.get("tag_name", "")
    if tag.startswith(prefix):
        print(tag)
        break
' "${version}"
}

create_release() {
  local version="$1"
  local sha256="$2"
  local release_tag="$3"
  local dmg_name="CodexAppMacIntel_${version}_${TARGET_ARCH_LABEL}_${RELEASE_DATE}.dmg"
  local zip_name="CodexAppMacIntelBuilder_${version}_${TARGET_ARCH_LABEL}_${RELEASE_DATE}.zip"
  local title="Codex Mac Intel for macOS ${version} ${TARGET_ARCH_LABEL} ${RELEASE_DATE}"
  local notes_file="${WORK_DIR}/release-notes.md"

  cat > "${notes_file}" <<EOF
- Platform: Mac
- Operating system: macOS
- CPU architecture: Intel x86_64
- Source app version: ${version}
- Source DMG URL: ${SOURCE_DMG_URL}
- Source DMG sha256: ${sha256}
- Build date: $(date +"%Y-%m-%d")
- Assets:
  - ${dmg_name}
  - ${zip_name}
EOF

  "${REPO_ROOT}/build-intel.sh" "${DOWNLOADED_DMG}"
  gh release create "${release_tag}" \
    "${REPO_ROOT}/${dmg_name}" \
    "${REPO_ROOT}/${zip_name}" \
    --target "${GITHUB_REF_NAME:-main}" \
    --title "${title}" \
    --notes-file "${notes_file}"
}

main() {
  local source_sha256=""
  local source_version=""
  local existing_release_tag=""
  local release_tag=""
  local action=""
  local note=""

  ensure_tracking_files
  load_state
  source_sha256="$(download_source_dmg)"
  source_version="$(read_source_version)"
  release_tag="v${source_version}-${TARGET_ARCH_LABEL}-${RELEASE_DATE}"
  emit_output "source_version" "${source_version}"
  emit_output "release_tag" "${release_tag}"

  if [[ "${source_version}" == "${LAST_SEEN_VERSION}" && "${source_sha256}" == "${LAST_SEEN_SHA256}" ]]; then
    action="no_update"
    note="same_version_and_sha"
    release_tag="${LAST_RELEASE_TAG}"
  else
    existing_release_tag="$(find_existing_release_for_version "${source_version}" || true)"
    if [[ -n "${existing_release_tag}" && -z "${LAST_SEEN_VERSION}" ]]; then
      action="no_update"
      note="bootstrap_synced_from_existing_release:${existing_release_tag}"
      release_tag="${existing_release_tag}"
    else
      action="released"
      note="new_upstream_artifact"
      create_release "${source_version}" "${source_sha256}" "${release_tag}"
    fi
  fi

  persist_state "${source_version}" "${source_sha256}" "${release_tag}" "${action}"
  append_history "${source_version}" "${source_sha256}" "${action}" "${release_tag}" "${note}"
  emit_output "action" "${action}"
  emit_output "commit_message" "automation: ${action} Codex ${source_version}"
}

main "$@"
