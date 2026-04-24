#!/usr/bin/env bash
set -euo pipefail

# Resolve script and workspace paths.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PARENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_BASE="${SCRIPT_DIR}/.tmp"
LOG_FILE="${SCRIPT_DIR}/log.txt"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
RELEASE_DATE="$(date +%Y%m%d)"
WORK_DIR="${TMP_BASE}/codex_intel_build_${RUN_ID}"
MOUNT_POINT="${WORK_DIR}/mount"
OUTPUT_DMG_PREFIX="CodexAppMacIntel"
SCRIPT_PACKAGE_PREFIX="CodexAppMacIntelBuilder"
TARGET_ARCH_LABEL="x64"
GITHUB_RELEASE_REPO="${GITHUB_RELEASE_REPO:-}"
DEFAULT_GITHUB_RELEASE_REPO="MisonL/Codex-Mac-Intel-Converter-Sh"
SOURCE_X64_APPCAST_URL="${SOURCE_X64_APPCAST_URL:-https://persistent.oaistatic.com/codex-app-prod/appcast-x64.xml}"
OFFICIAL_X64_APP_CANDIDATES_ENV="${OFFICIAL_X64_APP_CANDIDATES:-/Applications/Codex.app}"

OUTPUT_DMG=""
SCRIPT_RELEASE_ARCHIVE=""
RELEASE_BASENAME=""
APP_VERSION=""
APP_EXECUTABLE=""
APP_BUNDLE_ID=""
PATCH_SCRIPT_PATH=""

# Runtime flags/state used by cleanup and mount logic.
ATTACHED_BY_SCRIPT=0
SOURCE_APP=""
SOURCE_KIND=""
DOWNLOADED_X64_DONOR_ZIP=""
IFS=':' read -r -a OFFICIAL_X64_APP_CANDIDATES <<< "${OFFICIAL_X64_APP_CANDIDATES_ENV}"

timestamp() {
  date "+%Y-%m-%d %H:%M:%S"
}

log() {
  printf "[%s] %s\n" "$(timestamp)" "$*"
}

log_stderr() {
  printf "[%s] %s\n" "$(timestamp)" "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

plist_get() {
  local plist_file="$1"
  local plist_key="$2"

  /usr/libexec/PlistBuddy -c "Print :${plist_key}" "${plist_file}" 2>/dev/null
}

sanitize_filename_component() {
  printf '%s' "$1" | tr -cs 'A-Za-z0-9._-' '_'
}

resolve_patch_script_path() {
  local candidate=""

  for candidate in \
    "${SCRIPT_DIR}/scripts/patch-codex-desktop.mjs" \
    "${SCRIPT_DIR}/patch-codex-desktop.mjs"; do
    if [[ -f "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  return 1
}

derive_github_release_repo() {
  local remote_url=""
  local derived_repo=""

  if [[ -n "${GITHUB_RELEASE_REPO}" ]]; then
    printf '%s\n' "${GITHUB_RELEASE_REPO}"
    return 0
  fi

  if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
    printf '%s\n' "${GITHUB_REPOSITORY}"
    return 0
  fi

  if command -v git >/dev/null 2>&1; then
    remote_url="$(git -C "${SCRIPT_DIR}" remote get-url origin 2>/dev/null || true)"
  fi
  if [[ -n "${remote_url}" ]]; then
    derived_repo="$(printf '%s' "${remote_url}" | sed -E 's#(git@github\.com:|https://github\.com/)##; s#\.git$##')"
    if [[ "${derived_repo}" == */* ]]; then
      printf '%s\n' "${derived_repo}"
      return 0
    fi
  fi

  printf '%s\n' "${DEFAULT_GITHUB_RELEASE_REPO}"
}

upsert_plist_string() {
  local plist_file="$1"
  local plist_key="$2"
  local plist_value="$3"

  /usr/libexec/PlistBuddy -c "Set :${plist_key} ${plist_value}" "${plist_file}" >/dev/null 2>&1 || \
    /usr/libexec/PlistBuddy -c "Add :${plist_key} string ${plist_value}" "${plist_file}" >/dev/null
}

rename_helper_app() {
  local old_name="$1"
  local new_name="$2"
  local bundle_id_suffix="$3"
  local old_app="${TARGET_APP}/Contents/Frameworks/${old_name}.app"
  local new_app="${TARGET_APP}/Contents/Frameworks/${new_name}.app"
  local helper_plist=""

  [[ -d "${old_app}" ]] || die "Helper app not found: ${old_app}"
  mv "${old_app}" "${new_app}"
  if [[ -f "${new_app}/Contents/MacOS/${old_name}" ]]; then
    mv "${new_app}/Contents/MacOS/${old_name}" "${new_app}/Contents/MacOS/${new_name}"
  fi

  helper_plist="${new_app}/Contents/Info.plist"
  upsert_plist_string "${helper_plist}" "CFBundleExecutable" "${new_name}"
  upsert_plist_string "${helper_plist}" "CFBundleName" "${new_name}"
  upsert_plist_string "${helper_plist}" "CFBundleDisplayName" "${new_name}"
  upsert_plist_string "${helper_plist}" "CFBundleIdentifier" "${APP_BUNDLE_ID}.${bundle_id_suffix}"
}

find_mounted_app_for_image() {
  local image_path="$1"

  hdiutil info | awk -v image="${image_path}" '
    /^================================================$/ {
      if (matched) {
        exit
      }
      matched = 0
      next
    }
    $1 == "image-path" {
      current = substr($0, index($0, ":") + 2)
      matched = (current == image)
      next
    }
    matched && $1 ~ /^\/dev\// && NF >= 3 {
      mount_path = $0
      sub(/^([^[:space:]]+[[:space:]]+){2}/, "", mount_path)
      if (mount_path != "") {
        print mount_path "/Codex.app"
        exit
      }
    }
  '
}

find_zip_extracted_app() {
  local search_root="$1"

  find "${search_root}" -maxdepth 3 -type d -name "Codex.app" | sort | head -n 1
}

app_version_for_path() {
  local app_path="$1"
  local info_plist="${app_path}/Contents/Info.plist"
  local version=""

  [[ -f "${info_plist}" ]] || return 1
  version="$(plist_get "${info_plist}" "CFBundleShortVersionString" || true)"
  if [[ -z "${version}" ]]; then
    version="$(plist_get "${info_plist}" "CFBundleVersion" || true)"
  fi
  [[ -n "${version}" ]] || return 1
  printf '%s\n' "${version}"
}

app_executable_for_path() {
  local app_path="$1"
  local info_plist="${app_path}/Contents/Info.plist"

  [[ -f "${info_plist}" ]] || return 1
  plist_get "${info_plist}" "CFBundleExecutable"
}

is_x64_binary() {
  local binary_path="$1"
  local file_output=""

  [[ -f "${binary_path}" ]] || return 1
  file_output="$(file "${binary_path}")"
  [[ "${file_output}" == *"x86_64"* ]]
}

resolve_input_source() {
  local explicit_source="${1:-}"
  local found_sources=()
  local found_source=""

  if [[ -n "${explicit_source}" ]]; then
    if [[ -d "${explicit_source}" ]]; then
      cd "${explicit_source}" >/dev/null 2>&1 && pwd
      return 0
    fi
    cd "$(dirname "${explicit_source}")" >/dev/null 2>&1
    printf '%s/%s\n' "$(pwd)" "$(basename "${explicit_source}")"
    return 0
  fi

  if [[ -f "${SCRIPT_PARENT_DIR}/Codex.dmg" ]]; then
    printf '%s\n' "${SCRIPT_PARENT_DIR}/Codex.dmg"
    return 0
  fi

  while IFS= read -r found_source; do
    found_sources+=("${found_source}")
  done < <(
    find "${SCRIPT_PARENT_DIR}" -maxdepth 1 \
      \( -type f \( -name "*.dmg" -o -name "*.zip" \) -o -type d -name "*.app" \) \
      ! -name "${OUTPUT_DMG_PREFIX}.dmg" \
      ! -name "${OUTPUT_DMG_PREFIX}_*.dmg" \
      ! -name "${SCRIPT_PACKAGE_PREFIX}_*.zip" | sort
  )

  if [[ ${#found_sources[@]} -eq 0 ]]; then
    die "No source artifact found. Pass a Codex .dmg, .zip, or .app path explicitly."
  fi
  if [[ ${#found_sources[@]} -gt 1 ]]; then
    printf '%s\n' "${found_sources[@]}"
    die "Multiple source artifacts found. Pass the source path explicitly."
  fi

  printf '%s\n' "${found_sources[0]}"
}

prepare_source_app() {
  local input_source="$1"
  local zip_extract_dir=""
  local extracted_app=""

  if [[ -d "${input_source}" && "${input_source}" == *.app ]]; then
    SOURCE_KIND="app"
    SOURCE_APP="${input_source}"
    return 0
  fi

  case "${input_source}" in
    *.dmg)
      SOURCE_KIND="dmg"
      log "Mounting source DMG in read-only mode"
      mkdir -p "${MOUNT_POINT}"
      if hdiutil attach -readonly -nobrowse -mountpoint "${MOUNT_POINT}" "${input_source}" >/dev/null; then
        ATTACHED_BY_SCRIPT=1
        SOURCE_APP="${MOUNT_POINT}/Codex.app"
      else
        SOURCE_APP="$(find_mounted_app_for_image "${input_source}" || true)"
        if [[ -d "${SOURCE_APP}" ]]; then
          log "Using existing mounted app: ${SOURCE_APP}"
        elif [[ -d "/Volumes/Codex Installer/Codex.app" ]]; then
          SOURCE_APP="/Volumes/Codex Installer/Codex.app"
          log "Using existing mounted volume: ${SOURCE_APP}"
        else
          die "Failed to mount DMG and no fallback mounted Codex.app found"
        fi
      fi
      ;;
    *.zip)
      SOURCE_KIND="zip"
      zip_extract_dir="${WORK_DIR}/source-zip"
      mkdir -p "${zip_extract_dir}"
      log "Extracting source ZIP"
      ditto -x -k "${input_source}" "${zip_extract_dir}"
      extracted_app="$(find_zip_extracted_app "${zip_extract_dir}" || true)"
      [[ -n "${extracted_app}" ]] || die "Codex.app not found inside ZIP: ${input_source}"
      SOURCE_APP="${extracted_app}"
      ;;
    *)
      die "Unsupported source artifact: ${input_source}. Expected .dmg, .zip, or .app"
      ;;
  esac

  [[ -d "${SOURCE_APP}" ]] || die "Codex.app not found in source artifact: ${input_source}"
}

copy_bundle() {
  local source_path="$1"
  local destination_path="$2"

  rm -rf "${destination_path}"
  ditto "${source_path}" "${destination_path}"
}

find_local_x64_donor_app() {
  local source_version="$1"
  local candidate=""
  local candidate_version=""
  local candidate_executable=""

  for candidate in "${OFFICIAL_X64_APP_CANDIDATES[@]}"; do
    if [[ ! -d "${candidate}" ]]; then
      continue
    fi
    candidate_version="$(app_version_for_path "${candidate}" || true)"
    [[ "${candidate_version}" == "${source_version}" ]] || continue
    candidate_executable="$(app_executable_for_path "${candidate}" || true)"
    [[ -n "${candidate_executable}" ]] || continue
    if is_x64_binary "${candidate}/Contents/MacOS/${candidate_executable}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  return 1
}

lookup_appcast_enclosure_url() {
  local appcast_url="$1"
  local expected_version="$2"

  python3 - "$appcast_url" "$expected_version" <<'PY'
import sys
import urllib.request
import xml.etree.ElementTree as ET

appcast_url = sys.argv[1]
expected_version = sys.argv[2]

request = urllib.request.Request(
    appcast_url,
    headers={"User-Agent": "CodexIntelBuilder/1.0"},
)
with urllib.request.urlopen(request, timeout=60) as response:
    data = response.read()

root = ET.fromstring(data)
channel = root.find("channel")
if channel is None:
    raise SystemExit("Missing channel in appcast")

for item in channel.findall("item"):
    version = item.findtext("{http://www.andymatuschak.org/xml-namespaces/sparkle}shortVersionString") or item.findtext("title") or ""
    if version != expected_version:
        continue
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise SystemExit("Missing enclosure in matching appcast item")
    url = enclosure.attrib.get("url", "").strip()
    if not url:
        raise SystemExit("Matching appcast item is missing enclosure URL")
    print(url)
    raise SystemExit(0)

raise SystemExit(1)
PY
}

download_x64_donor_zip() {
  local source_version="$1"
  local donor_dir="${WORK_DIR}/x64-donor"
  local donor_zip_url=""
  local donor_zip_path=""
  local extracted_app=""

  donor_zip_url="$(lookup_appcast_enclosure_url "${SOURCE_X64_APPCAST_URL}" "${source_version}" || true)"
  [[ -n "${donor_zip_url}" ]] || die "Cannot find matching x64 donor ZIP for version ${source_version} in ${SOURCE_X64_APPCAST_URL}"

  mkdir -p "${donor_dir}"
  donor_zip_path="${donor_dir}/$(basename "${donor_zip_url}")"
  DOWNLOADED_X64_DONOR_ZIP="${donor_zip_path}"
  log_stderr "Downloading matching x64 donor ZIP: ${donor_zip_url}"
  curl --fail --location --silent --show-error \
    --connect-timeout 30 --max-time 900 \
    --retry 3 --retry-delay 5 --retry-all-errors \
    "${donor_zip_url}" --output "${donor_zip_path}"

  log_stderr "Extracting x64 donor ZIP"
  ditto -x -k "${donor_zip_path}" "${donor_dir}/unzipped"
  extracted_app="$(find_zip_extracted_app "${donor_dir}/unzipped" || true)"
  [[ -n "${extracted_app}" ]] || die "Codex.app not found inside donor ZIP: ${donor_zip_path}"
  printf '%s\n' "${extracted_app}"
}

prepare_x64_donor_app() {
  local source_version="$1"
  local donor_app=""

  donor_app="$(find_local_x64_donor_app "${source_version}" || true)"
  if [[ -n "${donor_app}" ]]; then
    log_stderr "Using local x64 donor app: ${donor_app}"
    printf '%s\n' "${donor_app}"
    return 0
  fi

  donor_app="$(download_x64_donor_zip "${source_version}")"
  [[ -n "${donor_app}" ]] || die "Failed to prepare x64 donor app for version ${source_version}"
  log_stderr "Using downloaded x64 donor app: ${donor_app}"
  printf '%s\n' "${donor_app}"
}

sync_path_from_donor() {
  local donor_app="$1"
  local relative_path="$2"
  local donor_path="${donor_app}/${relative_path}"
  local target_path="${TARGET_APP}/${relative_path}"

  [[ -e "${donor_path}" ]] || die "Missing donor path: ${donor_path}"
  rm -rf "${target_path}"
  mkdir -p "$(dirname "${target_path}")"
  ditto "${donor_path}" "${target_path}"
}

sync_x64_donor_resources() {
  local donor_app="$1"
  local donor_version=""

  donor_version="$(app_version_for_path "${donor_app}" || true)"
  [[ "${donor_version}" == "${APP_VERSION_RAW}" ]] || die "Donor app version mismatch: expected ${APP_VERSION_RAW}, got ${donor_version:-<empty>}"

  log "Syncing x64 donor resources from official Intel build"
  sync_path_from_donor "${donor_app}" "Contents/Resources/node"
  sync_path_from_donor "${donor_app}" "Contents/Resources/node_repl"
  sync_path_from_donor "${donor_app}" "Contents/Resources/native"
  sync_path_from_donor "${donor_app}" "Contents/Resources/plugins"

  rm -f "${TARGET_APP}/Contents/Resources/codex_chronicle"
  rm -f "${TARGET_APP}/Contents/Resources/app.asar.unpacked/codex_chronicle"
}

assert_no_arm64_only_binary() {
  local binary_path="$1"
  local file_output=""

  [[ -e "${binary_path}" ]] || return 0
  file_output="$(file "${binary_path}")"
  echo "${file_output}"
  if [[ "${file_output}" == *"Mach-O"* && "${file_output}" == *"arm64"* && "${file_output}" != *"x86_64"* ]]; then
    die "Found arm64-only binary in Intel output: ${binary_path}"
  fi
}

validate_target_architecture() {
  local binary=""
  local plugin_binary=""

  log "Validating key binaries are usable on x86_64"
  for binary in \
    "${TARGET_APP}/Contents/MacOS/${APP_EXECUTABLE}" \
    "${TARGET_APP}/Contents/Resources/codex" \
    "${TARGET_APP}/Contents/Resources/rg" \
    "${TARGET_APP}/Contents/Resources/node" \
    "${TARGET_APP}/Contents/Resources/node_repl" \
    "${TARGET_APP}/Contents/Resources/native/launch-services-helper" \
    "${TARGET_APP}/Contents/Resources/app.asar.unpacked/node_modules/better-sqlite3/build/Release/better_sqlite3.node" \
    "${TARGET_APP}/Contents/Resources/app.asar.unpacked/node_modules/node-pty/build/Release/pty.node"; do
    assert_no_arm64_only_binary "${binary}"
  done

  if [[ -d "${TARGET_APP}/Contents/Resources/plugins" ]]; then
    while IFS= read -r plugin_binary; do
      assert_no_arm64_only_binary "${plugin_binary}"
    done < <(
      find "${TARGET_APP}/Contents/Resources/plugins" -type f \
        \( -perm -111 -o -name "*.node" \) | sort
    )
  fi

  [[ ! -e "${TARGET_APP}/Contents/Resources/codex_chronicle" ]] || die "Unexpected codex_chronicle residue found in Intel output"
}

usage() {
  cat <<'EOF'
Usage:
  ./build-intel.sh [path/to/Codex.dmg|path/to/Codex.zip|path/to/Codex.app]

Behavior:
  - Accepts source Codex .dmg, .zip, or .app
  - Never modifies the original source artifact
  - Uses .tmp/* for all build steps
  - Uses a matching official x64 donor app to replace arm64-only runtime resources
  - Writes full logs to log.txt
  - Produces release-named DMG and script bundle artifacts
EOF
}

cleanup() {
  local exit_code=$?

  if [[ "${ATTACHED_BY_SCRIPT}" -eq 1 && -d "${MOUNT_POINT}" ]]; then
    hdiutil detach "${MOUNT_POINT}" >/dev/null 2>&1 || hdiutil detach -force "${MOUNT_POINT}" >/dev/null 2>&1 || true
  fi

  if [[ ${exit_code} -ne 0 ]]; then
    log "Build failed. See ${LOG_FILE}"
    log "Temporary files kept at: ${WORK_DIR}"
  fi
}
trap cleanup EXIT

# Prepare log file and mirror output to console + log.txt.
mkdir -p "${TMP_BASE}"
: > "${LOG_FILE}"
exec > >(tee -a "${LOG_FILE}") 2>&1

log "Starting Intel build pipeline"
log "Script dir: ${SCRIPT_DIR}"
log "Default source location: ${SCRIPT_PARENT_DIR}/Codex.dmg"
log "Work dir: ${WORK_DIR}"
mkdir -p "${WORK_DIR}"
PATCH_SCRIPT_PATH="$(resolve_patch_script_path || true)"
[[ -n "${PATCH_SCRIPT_PATH}" ]] || die "Cannot locate patch-codex-desktop.mjs next to build-intel.sh"
GITHUB_RELEASE_REPO="$(derive_github_release_repo)"
log "GitHub release repo: ${GITHUB_RELEASE_REPO}"

# Validate required tools early.
for cmd in curl ditto file codesign hdiutil node npm npx python3 xattr; do
  command -v "${cmd}" >/dev/null 2>&1 || die "Missing required command: ${cmd}"
done

if [[ $# -gt 0 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
  usage
  exit 0
fi

if [[ $# -gt 1 ]]; then
  usage
  die "Too many arguments"
fi

INPUT_SOURCE="$(resolve_input_source "${1:-}")"
[[ -e "${INPUT_SOURCE}" ]] || die "Source artifact not found: ${INPUT_SOURCE}"
log "Source artifact: ${INPUT_SOURCE}"

prepare_source_app "${INPUT_SOURCE}"
log "Source kind: ${SOURCE_KIND}"
log "Source app: ${SOURCE_APP}"

ORIG_APP="${WORK_DIR}/CodexOriginal.app"
TARGET_APP="${WORK_DIR}/Codex.app"
BUILD_PROJECT="${WORK_DIR}/build-project"
DMG_ROOT="${WORK_DIR}/dmg-root"
SCRIPT_RELEASE_DIR=""

# Copy app bundle from source to local writable work dir.
log "Copying source app bundle to work dir"
copy_bundle "${SOURCE_APP}" "${ORIG_APP}"

APP_INFO_PLIST="${ORIG_APP}/Contents/Info.plist"
[[ -f "${APP_INFO_PLIST}" ]] || die "Cannot read source app info plist"
APP_VERSION_RAW="$(plist_get "${APP_INFO_PLIST}" "CFBundleShortVersionString" || true)"
if [[ -z "${APP_VERSION_RAW}" ]]; then
  APP_VERSION_RAW="$(plist_get "${APP_INFO_PLIST}" "CFBundleVersion" || true)"
fi
[[ -n "${APP_VERSION_RAW}" ]] || die "Cannot detect source app version"
APP_EXECUTABLE="$(plist_get "${APP_INFO_PLIST}" "CFBundleExecutable" || true)"
[[ -n "${APP_EXECUTABLE}" ]] || die "Cannot detect source app executable name"
APP_BUNDLE_ID="$(plist_get "${APP_INFO_PLIST}" "CFBundleIdentifier" || true)"
[[ -n "${APP_BUNDLE_ID}" ]] || die "Cannot detect source app bundle identifier"
APP_VERSION="$(sanitize_filename_component "${APP_VERSION_RAW}")"
[[ -n "${APP_VERSION}" ]] || die "Cannot sanitize source app version for release name"
RELEASE_BASENAME="${APP_VERSION}_${TARGET_ARCH_LABEL}_${RELEASE_DATE}"
OUTPUT_DMG="${SCRIPT_DIR}/${OUTPUT_DMG_PREFIX}_${RELEASE_BASENAME}.dmg"
SCRIPT_RELEASE_ARCHIVE="${SCRIPT_DIR}/${SCRIPT_PACKAGE_PREFIX}_${RELEASE_BASENAME}.zip"
SCRIPT_RELEASE_DIR="${WORK_DIR}/release-scripts/${SCRIPT_PACKAGE_PREFIX}_${RELEASE_BASENAME}"
log "Detected source app version: ${APP_VERSION_RAW}"
log "Release basename: ${RELEASE_BASENAME}"

FRAMEWORK_INFO="${ORIG_APP}/Contents/Frameworks/Electron Framework.framework/Versions/A/Resources/Info.plist"
[[ -f "${FRAMEWORK_INFO}" ]] || die "Cannot read Electron framework info plist"
ELECTRON_VERSION="$(plist_get "${FRAMEWORK_INFO}" "CFBundleVersion" || true)"
[[ -n "${ELECTRON_VERSION}" ]] || die "Cannot detect Electron version from source app"

ASAR_FILE="${ORIG_APP}/Contents/Resources/app.asar"
[[ -f "${ASAR_FILE}" ]] || die "app.asar not found in source app"

# Read dependency versions from app.asar metadata.
ASAR_META_DIR="${WORK_DIR}/asar-meta"
mkdir -p "${ASAR_META_DIR}"
(
  cd "${ASAR_META_DIR}"
  npx --yes @electron/asar extract-file "${ASAR_FILE}" "node_modules/better-sqlite3/package.json"
  mv package.json better-sqlite3.package.json
  npx --yes @electron/asar extract-file "${ASAR_FILE}" "node_modules/node-pty/package.json"
  mv package.json node-pty.package.json
)

BS_PKG="${ASAR_META_DIR}/better-sqlite3.package.json"
NP_PKG="${ASAR_META_DIR}/node-pty.package.json"
[[ -f "${BS_PKG}" ]] || die "Cannot extract better-sqlite3 package.json from app.asar"
[[ -f "${NP_PKG}" ]] || die "Cannot extract node-pty package.json from app.asar"
BS_VERSION="$(node -p "require(process.argv[1]).version" "${BS_PKG}")"
NP_VERSION="$(node -p "require(process.argv[1]).version" "${NP_PKG}")"

log "Detected Electron version: ${ELECTRON_VERSION}"
log "Detected better-sqlite3 version: ${BS_VERSION}"
log "Detected node-pty version: ${NP_VERSION}"

# Build a temporary project to fetch x64 Electron/runtime artifacts.
log "Preparing x64 build project"
mkdir -p "${BUILD_PROJECT}"
cat > "${BUILD_PROJECT}/package.json" <<EOF
{
  "name": "codex-intel-rebuild",
  "private": true,
  "version": "1.0.0",
  "dependencies": {
    "@openai/codex": "latest",
    "better-sqlite3": "${BS_VERSION}",
    "electron": "${ELECTRON_VERSION}",
    "node-pty": "${NP_VERSION}"
  },
  "devDependencies": {
    "@electron/rebuild": "3.7.2"
  }
}
EOF

(
  cd "${BUILD_PROJECT}"
  npm install --no-audit --no-fund
)

# Use Electron x64 app template as the destination runtime.
log "Creating Intel app bundle from Electron runtime"
copy_bundle "${BUILD_PROJECT}/node_modules/electron/dist/Electron.app" "${TARGET_APP}"

# Convert the default Electron runtime shell into a packaged Codex app shell.
log "Renaming Electron runtime shell to ${APP_EXECUTABLE}"
mv "${TARGET_APP}/Contents/MacOS/Electron" "${TARGET_APP}/Contents/MacOS/${APP_EXECUTABLE}"
rename_helper_app "Electron Helper" "${APP_EXECUTABLE} Helper" "helper"
rename_helper_app "Electron Helper (Renderer)" "${APP_EXECUTABLE} Helper (Renderer)" "helper.renderer"
rename_helper_app "Electron Helper (GPU)" "${APP_EXECUTABLE} Helper (GPU)" "helper.gpu"
rename_helper_app "Electron Helper (Plugin)" "${APP_EXECUTABLE} Helper (Plugin)" "helper.plugin"

# Inject original Codex metadata and resources into the packaged x64 runtime shell.
log "Injecting Codex resources from source app"
rm -rf "${TARGET_APP}/Contents/Resources"
copy_bundle "${ORIG_APP}/Contents/Resources" "${TARGET_APP}/Contents/Resources"
cp "${ORIG_APP}/Contents/Info.plist" "${TARGET_APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSEnvironment:ELECTRON_RENDERER_URL string app://-/index.html" "${TARGET_APP}/Contents/Info.plist" >/dev/null 2>&1 || \
  /usr/libexec/PlistBuddy -c "Set :LSEnvironment:ELECTRON_RENDERER_URL app://-/index.html" "${TARGET_APP}/Contents/Info.plist" >/dev/null

# Replace arm64-only runtime resources with a matching official Intel donor build.
X64_DONOR_APP="$(prepare_x64_donor_app "${APP_VERSION_RAW}")"
sync_x64_donor_resources "${X64_DONOR_APP}"

# Patch packaged desktop metadata and updater logic inside app.asar.
log "Patching packaged desktop bundle for GitHub release updates"
ASAR_EXTRACT_DIR="${WORK_DIR}/asar-app"
rm -rf "${ASAR_EXTRACT_DIR}"
npx --yes @electron/asar extract "${TARGET_APP}/Contents/Resources/app.asar" "${ASAR_EXTRACT_DIR}"
node "${PATCH_SCRIPT_PATH}" \
  "${ASAR_EXTRACT_DIR}" \
  "${GITHUB_RELEASE_REPO}" \
  "v${APP_VERSION}-${TARGET_ARCH_LABEL}-${RELEASE_DATE}" \
  "${RELEASE_DATE}" \
  "$(basename "${OUTPUT_DMG}")" \
  "${TARGET_ARCH_LABEL}"
npx --yes @electron/asar pack "${ASAR_EXTRACT_DIR}" "${TARGET_APP}/Contents/Resources/app.asar"

# Rebuild native modules against Electron x64 ABI.
log "Rebuilding native modules for Electron ${ELECTRON_VERSION} x64"
(
  cd "${BUILD_PROJECT}"
  npx --yes @electron/rebuild -f -w better-sqlite3,node-pty --arch=x64 --version "${ELECTRON_VERSION}" -m "${BUILD_PROJECT}"
)

TARGET_UNPACKED="${TARGET_APP}/Contents/Resources/app.asar.unpacked"
[[ -d "${TARGET_UNPACKED}" ]] || die "Target app.asar.unpacked not found"

# Replace arm64 native artifacts with rebuilt x64 binaries.
log "Replacing native binaries inside app.asar.unpacked"
install -m 755 "${BUILD_PROJECT}/node_modules/better-sqlite3/build/Release/better_sqlite3.node" \
  "${TARGET_UNPACKED}/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
install -m 755 "${BUILD_PROJECT}/node_modules/node-pty/build/Release/pty.node" \
  "${TARGET_UNPACKED}/node_modules/node-pty/build/Release/pty.node"
install -m 755 "${BUILD_PROJECT}/node_modules/node-pty/build/Release/spawn-helper" \
  "${TARGET_UNPACKED}/node_modules/node-pty/build/Release/spawn-helper"

NODE_PTY_BIN_SRC="$(find "${BUILD_PROJECT}/node_modules/node-pty/bin" -type f -name "node-pty.node" | grep "darwin-x64" | head -n 1 || true)"
if [[ -n "${NODE_PTY_BIN_SRC}" ]]; then
  mkdir -p "${TARGET_UNPACKED}/node_modules/node-pty/bin/darwin-x64-143"
  install -m 755 "${NODE_PTY_BIN_SRC}" "${TARGET_UNPACKED}/node_modules/node-pty/bin/darwin-x64-143/node-pty.node"
  if [[ -f "${TARGET_UNPACKED}/node_modules/node-pty/bin/darwin-arm64-143/node-pty.node" ]]; then
    install -m 755 "${NODE_PTY_BIN_SRC}" "${TARGET_UNPACKED}/node_modules/node-pty/bin/darwin-arm64-143/node-pty.node"
  fi
fi

CLI_X64_ROOT="${BUILD_PROJECT}/node_modules/@openai/codex-darwin-x64/vendor/x86_64-apple-darwin"
CLI_X64_BIN="${CLI_X64_ROOT}/codex/codex"
RG_X64_BIN="${CLI_X64_ROOT}/path/rg"
[[ -f "${CLI_X64_BIN}" ]] || die "x64 Codex CLI binary not found after npm install"
[[ -f "${RG_X64_BIN}" ]] || die "x64 rg binary not found after npm install"

log "Replacing bundled codex/rg binaries with x64 versions"
install -m 755 "${CLI_X64_BIN}" "${TARGET_APP}/Contents/Resources/codex"
install -m 755 "${CLI_X64_BIN}" "${TARGET_APP}/Contents/Resources/app.asar.unpacked/codex"
install -m 755 "${RG_X64_BIN}" "${TARGET_APP}/Contents/Resources/rg"

log "Removing non-runtime debug symbol bundles"
find "${TARGET_APP}/Contents/Resources" -type d -name "*.dSYM" -prune -exec rm -rf {} +

# Sparkle native addon is still routed through GitHub release updater in this repo.
log "Disabling bundled Sparkle native addon in favor of GitHub release updater"
rm -f "${TARGET_APP}/Contents/Resources/native/sparkle.node"
rm -f "${TARGET_APP}/Contents/Resources/app.asar.unpacked/native/sparkle.node"

validate_target_architecture

log "Signing app ad-hoc"
xattr -cr "${TARGET_APP}" || true
codesign --force --deep --sign - --timestamp=none "${TARGET_APP}"
codesign --verify --deep --strict "${TARGET_APP}"

log "Building output DMG: ${OUTPUT_DMG}"
rm -f "${OUTPUT_DMG}"
mkdir -p "${DMG_ROOT}"
copy_bundle "${TARGET_APP}" "${DMG_ROOT}/Codex.app"
ln -s /Applications "${DMG_ROOT}/Applications"
hdiutil create -volname "Codex App Mac Intel" -srcfolder "${DMG_ROOT}" -ov -format UDZO "${OUTPUT_DMG}" >/dev/null

log "Packaging release scripts: ${SCRIPT_RELEASE_ARCHIVE}"
rm -f "${SCRIPT_RELEASE_ARCHIVE}"
mkdir -p "${SCRIPT_RELEASE_DIR}"
install -m 755 "${SCRIPT_DIR}/build-intel.sh" "${SCRIPT_RELEASE_DIR}/build-intel.sh"
install -m 755 "${SCRIPT_DIR}/scripts/patch-codex-desktop.mjs" "${SCRIPT_RELEASE_DIR}/patch-codex-desktop.mjs"
cp "${SCRIPT_DIR}/README.md" "${SCRIPT_RELEASE_DIR}/README.md"
cp "${SCRIPT_DIR}/package.json" "${SCRIPT_RELEASE_DIR}/package.json"
cp "${SCRIPT_DIR}/.gitignore" "${SCRIPT_RELEASE_DIR}/.gitignore"
ditto -c -k --sequesterRsrc --keepParent "${SCRIPT_RELEASE_DIR}" "${SCRIPT_RELEASE_ARCHIVE}"

log "Done"
log "Output DMG: ${OUTPUT_DMG}"
log "Script bundle: ${SCRIPT_RELEASE_ARCHIVE}"
log "Build log: ${LOG_FILE}"
log "Work dir: ${WORK_DIR}"
