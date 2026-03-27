# Codex App for Mac Intel (Unofficial)

Minimal helper repo to rebuild the official `Codex.dmg` into an Intel-compatible macOS app image, and to automate GitHub Release checks/publishing.

This is an unofficial adaptation approach, similar in spirit to the Linux community port:  
[Codex App for Linux (unofficial)](https://github.com/areu01or00/Codex-App-Linux/)

## What is included

- `build-intel.sh` — main build script
- `scripts/patch-codex-desktop.mjs` — patches packaged app metadata and updater logic inside `app.asar`
- `scripts/check-codex-release.sh` — checks upstream `Codex.dmg`, compares state, and publishes GitHub Release when needed
- `.github/workflows/codex-release-check.yml` — scheduled/manual GitHub Actions workflow
- `.gitignore` — ignores build artifacts and local temp files
- `package.json` — optional convenience `npm` script wrapper

## Requirements

- macOS
- `bash`, `hdiutil`, `ditto`, `codesign`
- Node.js + npm (used by the script to fetch Electron/runtime dependencies)

## Quick usage

1. Put your original `Codex.dmg` next to the repo folder (not inside it), so it is available as `../Codex.dmg`.
2. Run:

```bash
chmod +x ./build-intel.sh
./build-intel.sh
```

Or:

```bash
./build-intel.sh /absolute/path/to/Codex.dmg
```

## Output

- `CodexAppMacIntel_<原始版本>_x64_<YYYYMMDD>.dmg` — rebuilt Intel-targeted output
- `CodexAppMacIntelBuilder_<原始版本>_x64_<YYYYMMDD>.zip` — release bundle containing `build-intel.sh`, `patch-codex-desktop.mjs`, `README.md`, `package.json`, `.gitignore`
- `log.txt` — full build log
- `.tmp/` — temporary build workspace

## Current behavior

- The rebuilt app is a packaged `Codex.app`, not a transplanted `Electron.app` shell
- The Intel app removes the arm64-only native Sparkle addon
- macOS update checks are redirected to the current repository's GitHub Releases
- The patcher supports both currently observed upstream bundle layouts:
  - legacy `deeplinks-*.js`
  - current `product-name-*.js`

## Automation

- GitHub Actions workflow: `.github/workflows/codex-release-check.yml`
- Schedule: every day at `09:00` Asia/Shanghai
- Source DMG: `https://persistent.oaistatic.com/codex-app-prod/Codex.dmg`
- Tracking state: `.github/codex-release-state.env`
- Check history: `docs/release-checks/history.tsv`
- State/history commits are only pushed automatically when the workflow runs on `main`
