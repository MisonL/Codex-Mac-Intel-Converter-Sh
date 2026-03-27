#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_BUILD_ROOT="${REPO_ROOT}/.tmp/codex_intel_build_20260326_212136"
BUILD_ROOT="${BUILD_ROOT:-${DEFAULT_BUILD_ROOT}}"
ELECTRON_APP="${BUILD_ROOT}/build-project/node_modules/electron/dist/Electron.app"
CONVERTED_APP="${BUILD_ROOT}/Codex.app"
ORIGINAL_APP_CANDIDATES=(
  "/private/var/folders/hq/q19jry150l16mrrbkh7wm0_m0000gn/T/MgnrJQ/Codex.app"
  "/Volumes/Codex Installer/Codex.app"
)

find_original_app() {
  local app_path=""
  for app_path in "${ORIGINAL_APP_CANDIDATES[@]}"; do
    if [[ -d "${app_path}" ]]; then
      printf '%s\n' "${app_path}"
      return 0
    fi
  done
  return 1
}

run_packaged_probe() {
  local app_copy_name="$1"
  local exec_name="$2"
  local test_root="$3"

  rm -rf "${test_root}"
  mkdir -p "${test_root}"
  cp -R "${ELECTRON_APP}" "${test_root}/${app_copy_name}"
  if [[ "${exec_name}" != "Electron" ]]; then
    mv "${test_root}/${app_copy_name}/Contents/MacOS/Electron" \
      "${test_root}/${app_copy_name}/Contents/MacOS/${exec_name}"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable ${exec_name}" \
      "${test_root}/${app_copy_name}/Contents/Info.plist" >/dev/null
  fi

  mkdir -p "${test_root}/${app_copy_name}/Contents/Resources/app"
  cat > "${test_root}/${app_copy_name}/Contents/Resources/app/package.json" <<'EOF'
{
  "name": "packaged-state-test",
  "version": "1.0.0",
  "main": "main.js"
}
EOF
  TEST_ROOT_VALUE="${test_root}" cat > "${test_root}/${app_copy_name}/Contents/Resources/app/main.js" <<'EOF'
const { app } = require('electron');
const fs = require('fs');
const path = require('path');
app.whenReady().then(() => {
  const out = {
    isPackaged: app.isPackaged,
    defaultApp: !!process.defaultApp,
    execPath: process.execPath,
    appPath: app.getAppPath(),
  };
  fs.writeFileSync(path.join(process.env.TEST_ROOT_VALUE, 'result.json'), JSON.stringify(out, null, 2));
  app.quit();
});
EOF

  TEST_ROOT_VALUE="${test_root}" \
    "${test_root}/${app_copy_name}/Contents/MacOS/${exec_name}" \
    > "${test_root}/run.log" 2>&1 &
  local pid=$!
  local _=""
  for _ in $(seq 1 40); do
    if [[ -f "${test_root}/result.json" ]]; then
      break
    fi
    sleep 0.5
  done
  if [[ ! -f "${test_root}/result.json" ]]; then
    cat "${test_root}/run.log" >&2 || true
    kill "${pid}" >/dev/null 2>&1 || true
    wait "${pid}" >/dev/null 2>&1 || true
    return 1
  fi
  cat "${test_root}/result.json"
  wait "${pid}" >/dev/null 2>&1 || true
}

main() {
  local original_app=""
  original_app="$(find_original_app)"
  [[ -d "${ELECTRON_APP}" ]] || {
    echo "Missing Electron runtime for validation: ${ELECTRON_APP}" >&2
    exit 1
  }
  [[ -d "${CONVERTED_APP}" ]] || {
    echo "Missing converted app for validation: ${CONVERTED_APP}" >&2
    exit 1
  }

  echo "== Sparkle architecture check =="
  file "${original_app}/Contents/Resources/native/sparkle.node"
  if [[ -e "${CONVERTED_APP}/Contents/Resources/native/sparkle.node" ]]; then
    file "${CONVERTED_APP}/Contents/Resources/native/sparkle.node"
  else
    echo "converted sparkle.node: missing"
  fi

  echo
  echo "== app.isPackaged probe: default Electron shell =="
  run_packaged_probe "Electron.app" "Electron" "/tmp/electron-packaged-test-default"

  echo
  echo "== app.isPackaged probe: renamed shell/executable =="
  run_packaged_probe "Codex.app" "Codex" "/tmp/electron-packaged-test-renamed"
}

main "$@"
