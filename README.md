# Codex App for Mac Intel (Unofficial)

这个仓库把 OpenAI 官方 Codex for macOS 的上游安装包重新处理为 Intel 可运行版本，并自动检查上游新版本后发布 GitHub Release。

## 仓库内容

- `build-intel.sh`
  主构建脚本。支持输入官方 `Codex.dmg`、Sparkle `Codex-darwin-arm64-*.zip` 或现成 `Codex.app`。
- `scripts/check-codex-release.sh`
  读取官方 Sparkle appcast，检查最新版本并在需要时发布本仓库的 Intel Release。
- `scripts/patch-codex-desktop.mjs`
  修改 `app.asar` 内的更新逻辑，把内置更新改为当前仓库 GitHub Release 下载。
- `scripts/validate-release-updater.sh`
  本地验证 packaged 状态与更新器前提。
- `.github/workflows/codex-release-check.yml`
  每日定时和手动触发的自动化工作流。

## 依赖

- macOS
- `bash`、`hdiutil`、`ditto`、`codesign`、`xattr`
- `curl`、`python3`
- Node.js + npm

## 快速使用

直接传入官方安装源：

```bash
chmod +x ./build-intel.sh
./build-intel.sh /absolute/path/to/Codex.dmg
./build-intel.sh /absolute/path/to/Codex-darwin-arm64-26.422.21459.zip
./build-intel.sh /absolute/path/to/Codex.app
```

如果不传参数，脚本会优先使用仓库同级目录下的 `../Codex.dmg`，否则自动寻找唯一的 `.dmg`、`.zip` 或 `.app`。

## 产物

- `CodexAppMacIntel_<版本>_x64_<YYYYMMDD>.dmg`
- `CodexAppMacIntelBuilder_<版本>_x64_<YYYYMMDD>.zip`
- `log.txt`
- `.tmp/`

## 当前构建策略

- 以官方 arm64 安装源为基准复制业务资源。
- 再为相同版本自动引入官方 x64 donor 资源，优先使用本机 `/Applications/Codex.app`，否则从 `appcast-x64.xml` 下载对应版本 ZIP。
- donor 会同步 `node`、`node_repl`、`Resources/native` 和 `Resources/plugins`，用来清除 mixed-arch 残留。
- 仍然禁用原生 Sparkle addon，继续使用当前仓库的 GitHub Release 更新方案。

## 自动化

- 工作流：`.github/workflows/codex-release-check.yml`
- 调度：每天 `09:00`（Asia/Shanghai），对应 GitHub Actions UTC cron `0 1 * * *`
- 上游检测源：
  - arm64 appcast: `https://persistent.oaistatic.com/codex-app-prod/appcast.xml`
  - x64 donor appcast: `https://persistent.oaistatic.com/codex-app-prod/appcast-x64.xml`
- 状态文件：`.github/codex-release-state.env`
- 历史记录：`docs/release-checks/history.tsv`

自动化现在不再盯 `Codex.dmg`，因为官方最新版本首先经由 Sparkle appcast 发布；同版本 x64 donor 也从 appcast-x64 获取。
