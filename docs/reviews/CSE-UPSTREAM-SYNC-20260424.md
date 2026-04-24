# CSE Upstream Sync Review 2026-04-24

## 结论

- 官方 Codex 上游最新版本已通过 Sparkle appcast 发布，不应继续只盯 `Codex.dmg`。
- 本轮已将自动化检测源切到 arm64 appcast，并在构建时为同版本自动引入官方 x64 donor。
- 新构建产物 `26.422.21459` 已验证消除已知 mixed-arch 运行时残留。

## 上游事实

- arm64 appcast: `https://persistent.oaistatic.com/codex-app-prod/appcast.xml`
- x64 appcast: `https://persistent.oaistatic.com/codex-app-prod/appcast-x64.xml`
- 初次对齐时的最新版本: `26.422.21459`
- arm64 安装源: `Codex-darwin-arm64-26.422.21459.zip`
- x64 donor 安装源: `Codex-darwin-x64-26.422.21459.zip`
- 最终复核期间，官方 appcast 已继续推进到 `26.422.21637`，说明上游更新节奏确实以 appcast 为准而不是 `Codex.dmg`

## 本轮修改

- `build-intel.sh`
  - 支持 `.dmg`、`.zip`、`.app` 输入。
  - 构建时自动寻找同版本官方 x64 donor，优先本机 `/Applications/Codex.app`，否则从 `appcast-x64.xml` 下载。
  - donor 同步 `Resources/node`、`Resources/node_repl`、`Resources/native`、`Resources/plugins`。
  - 删除 `codex_chronicle` 和非运行时 `*.dSYM`，避免 arm64-only 残留。
- `scripts/check-codex-release.sh`
  - 改为解析 arm64 appcast 最新条目，不再依赖滞后的 `Codex.dmg`。
  - 先做本地 state 判定，再按需查询 GitHub Release，收紧 `no_update` 路径。
- `README.md`
  - 更新为 appcast 驱动和 donor 驱动的当前行为说明。

## 验证命令

```bash
bash -n build-intel.sh
bash -n scripts/check-codex-release.sh
node --check scripts/patch-codex-desktop.mjs
bash ./build-intel.sh ./.tmp/Codex-darwin-arm64-26.422.21459.zip
BUILD_ROOT="/Volumes/Work/code/Codex-Mac-Intel-Converter-Sh/.tmp/codex_intel_build_20260424_085105" \
  ORIGINAL_APP_CANDIDATES_ENV="/Applications/Codex.app" \
  bash ./scripts/validate-release-updater.sh
```

## 验证结果

- 构建成功产出：
  - `CodexAppMacIntel_26.422.21459_x64_20260424.dmg`
  - `CodexAppMacIntelBuilder_26.422.21459_x64_20260424.zip`
- 新工作目录：
  - `.tmp/codex_intel_build_20260424_085931`
- 关键二进制均为 `x86_64`：
  - `Contents/MacOS/Codex`
  - `Contents/Resources/node`
  - `Contents/Resources/node_repl`
  - `Contents/Resources/native/launch-services-helper`
  - `better_sqlite3.node`
  - `pty.node`
- 全量资源扫描（排除 `.dSYM`）未发现 arm64-only Mach-O。
- `scripts/check-codex-release.sh` 的 `same_version_and_sha -> no_update` 路径已通过临时 state/history 文件验证。

## 与同版本官方 x64 donor 的差异

- 保持一致：
  - 版本号相同：`26.422.21459`
  - 主可执行同为 `x86_64`
  - 无 `codex_chronicle`
  - 无 `computer-use` 插件目录
- 仍然不同：
  - 官方保留 `Resources/native/sparkle.node` 和 `Frameworks/Sparkle.framework`
  - 当前仓库转换版仍移除 Sparkle 原生更新链，继续使用 GitHub Release 更新逻辑

## 风险备注

- 本机 `/Applications/Codex.app` 当前安装版本仍是 `26.417.41555`，因此 donor 首选路径在本轮没有命中，实际使用的是下载到工作目录内的同版本 x64 donor ZIP。
