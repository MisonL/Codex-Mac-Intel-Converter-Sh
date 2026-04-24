#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_BASE="${REPO_ROOT}/.tmp/release-check"
STATE_FILE="${STATE_FILE:-${REPO_ROOT}/.github/codex-release-state.env}"
HISTORY_FILE="${HISTORY_FILE:-${REPO_ROOT}/docs/release-checks/history.tsv}"
SOURCE_APPCAST_URL="${SOURCE_APPCAST_URL:-https://persistent.oaistatic.com/codex-app-prod/appcast.xml}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
TARGET_ARCH_LABEL="x64"
RELEASE_TARGET_REF="${RELEASE_TARGET_REF:-main}"
RUN_AT_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
RELEASE_DATE="$(date +%Y%m%d)"
WORK_DIR="${TMP_BASE}/${RELEASE_DATE}_$(date +%H%M%S)"

LAST_SEEN_VERSION=""
LAST_SEEN_SHA256=""
LAST_RELEASE_TAG=""
LAST_CHECKED_AT_UTC=""
LAST_ACTION=""

log() {
  printf '[%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"
}

derive_github_repository() {
  local remote_url=""
  local derived_repo=""

  if [[ -n "${GITHUB_REPOSITORY}" ]]; then
    printf '%s\n' "${GITHUB_REPOSITORY}"
    return 0
  fi

  if command -v git >/dev/null 2>&1; then
    remote_url="$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null || true)"
  fi
  if [[ -n "${remote_url}" ]]; then
    derived_repo="$(printf '%s' "${remote_url}" | sed -E 's#(git@github\.com:|https://github\.com/)##; s#\.git$##')"
    if [[ "${derived_repo}" == */* ]]; then
      printf '%s\n' "${derived_repo}"
      return 0
    fi
  fi

  echo "Cannot determine GitHub repository. Set GITHUB_REPOSITORY or configure origin." >&2
  return 1
}

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
  log "Loaded state: version=${LAST_SEEN_VERSION:-<empty>} action=${LAST_ACTION:-<empty>} checked_at=${LAST_CHECKED_AT_UTC:-<empty>}"
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

fetch_latest_appcast_entry() {
  python3 - "$SOURCE_APPCAST_URL" <<'PY'
import sys
import urllib.request
import xml.etree.ElementTree as ET

appcast_url = sys.argv[1]
sparkle = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"

request = urllib.request.Request(
    appcast_url,
    headers={"User-Agent": "CodexIntelReleaseCheck/1.0"},
)
with urllib.request.urlopen(request, timeout=60) as response:
    root = ET.fromstring(response.read())

channel = root.find("channel")
if channel is None:
    raise SystemExit("Missing channel in appcast")

item = channel.find("item")
if item is None:
    raise SystemExit("Appcast has no items")

version = item.findtext(f"{sparkle}shortVersionString") or item.findtext("title") or ""
pub_date = item.findtext("pubDate") or ""
hardware = item.findtext(f"{sparkle}hardwareRequirements") or ""
enclosure = item.find("enclosure")
if enclosure is None:
    raise SystemExit("Latest appcast item is missing enclosure")
url = enclosure.attrib.get("url", "").strip()
if not version or not url:
    raise SystemExit("Latest appcast item is missing required fields")

print(version)
print(url)
print(pub_date)
print(hardware)
PY
}

download_source_artifact() {
  local source_url="$1"
  local output_path="${WORK_DIR}/$(basename "${source_url}")"

  mkdir -p "${WORK_DIR}"
  curl --fail --location --silent --show-error \
    --connect-timeout 30 --max-time 900 \
    --retry 3 --retry-delay 5 --retry-all-errors \
    "${source_url}" --output "${output_path}"
  printf '%s\n' "${output_path}"
}

sha256_file() {
  local file_path="$1"
  shasum -a 256 "${file_path}" | awk '{print $1}'
}

find_existing_release_for_artifact() {
  local version="$1"
  local sha256="$2"

  gh api "repos/${GITHUB_REPOSITORY}/releases?per_page=100" | python3 -c '
import json
import sys

version = sys.argv[1]
sha256 = sys.argv[2]
prefix = f"v{version}-x64-"
for release in json.load(sys.stdin):
    tag = release.get("tag_name", "")
    body = release.get("body", "")
    if tag.startswith(prefix) and f"Source artifact sha256: {sha256}" in body:
        print(tag)
        break
' "${version}" "${sha256}"
}

create_release() {
  local version="$1"
  local source_url="$2"
  local source_sha256="$3"
  local source_hardware="$4"
  local source_pub_date="$5"
  local source_artifact_path="$6"
  local release_tag="$7"
  local dmg_name="CodexAppMacIntel_${version}_${TARGET_ARCH_LABEL}_${RELEASE_DATE}.dmg"
  local zip_name="CodexAppMacIntelBuilder_${version}_${TARGET_ARCH_LABEL}_${RELEASE_DATE}.zip"
  local title="Codex Mac Intel for macOS ${version} ${TARGET_ARCH_LABEL} ${RELEASE_DATE}"
  local notes_file="${WORK_DIR}/release-notes.md"

  cat > "${notes_file}" <<EOF
- Platform: Mac
- Operating system: macOS
- CPU architecture: Intel x86_64
- Source app version: ${version}
- Source upstream architecture: ${source_hardware:-unknown}
- Source artifact URL: ${source_url}
- Source artifact sha256: ${source_sha256}
- Source published at (UTC): ${source_pub_date}
- Build date: $(date +"%Y-%m-%d")
- Assets:
  - ${dmg_name}
  - ${zip_name}
EOF

  "${REPO_ROOT}/build-intel.sh" "${source_artifact_path}"
  gh release create "${release_tag}" \
    "${REPO_ROOT}/${dmg_name}" \
    "${REPO_ROOT}/${zip_name}" \
    --target "${RELEASE_TARGET_REF}" \
    --title "${title}" \
    --notes-file "${notes_file}"
}

main() {
  local appcast_lines=()
  local source_version=""
  local source_url=""
  local source_pub_date=""
  local source_hardware=""
  local source_artifact_path=""
  local source_sha256=""
  local existing_release_tag=""
  local release_tag=""
  local action=""
  local note=""

  ensure_tracking_files
  GITHUB_REPOSITORY="$(derive_github_repository)"
  load_state

  while IFS= read -r line; do
    appcast_lines+=("${line}")
  done < <(fetch_latest_appcast_entry)

  [[ ${#appcast_lines[@]} -ge 2 ]] || {
    echo "Failed to parse latest appcast entry from ${SOURCE_APPCAST_URL}" >&2
    exit 1
  }

  source_version="${appcast_lines[0]}"
  source_url="${appcast_lines[1]}"
  source_pub_date="${appcast_lines[2]:-}"
  source_hardware="${appcast_lines[3]:-}"
  source_artifact_path="$(download_source_artifact "${source_url}")"
  source_sha256="$(sha256_file "${source_artifact_path}")"
  release_tag="v${source_version}-${TARGET_ARCH_LABEL}-${RELEASE_DATE}"

  emit_output "source_version" "${source_version}"
  emit_output "source_url" "${source_url}"
  emit_output "release_tag" "${release_tag}"

  if [[ "${source_version}" == "${LAST_SEEN_VERSION}" && "${source_sha256}" == "${LAST_SEEN_SHA256}" ]]; then
    action="no_update"
    note="same_version_and_sha"
    release_tag="${LAST_RELEASE_TAG}"
  else
    existing_release_tag="$(find_existing_release_for_artifact "${source_version}" "${source_sha256}" || true)"
  fi

  if [[ -z "${action}" && -n "${existing_release_tag}" ]]; then
    action="no_update"
    note="existing_release_found:${existing_release_tag}"
    release_tag="${existing_release_tag}"
  elif [[ -z "${action}" ]]; then
    action="released"
    if [[ "${source_version}" == "${LAST_SEEN_VERSION}" ]]; then
      note="same_version_new_sha"
    else
      note="new_upstream_artifact"
    fi
    create_release "${source_version}" "${source_url}" "${source_sha256}" "${source_hardware}" "${source_pub_date}" "${source_artifact_path}" "${release_tag}"
  fi

  persist_state "${source_version}" "${source_sha256}" "${release_tag}" "${action}"
  append_history "${source_version}" "${source_sha256}" "${action}" "${release_tag}" "${note}"
  emit_output "action" "${action}"
  emit_output "commit_message" "automation: ${action} Codex ${source_version}"
}

main "$@"
