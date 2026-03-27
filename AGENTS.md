# Repository Guidelines

## 项目结构与模块组织

- `build-intel.sh`：主构建脚本。负责把官方 `Codex.dmg` 转成 Intel 可用的 packaged `Codex.app`，补丁 `app.asar`，重建原生模块，重新签名并输出发布产物。
- `scripts/check-codex-release.sh`：上游版本检查与 GitHub Release 自动发布脚本。
- `scripts/patch-codex-desktop.mjs`：修改 `app.asar` 内的元数据和更新逻辑。
- `scripts/validate-release-updater.sh`：本地验证 packaged 状态、Sparkle 架构与更新器前提。
- `.github/workflows/codex-release-check.yml`：每日定时/手动触发的自动化工作流。
- `docs/reviews/`：验证记录与审查文档。
- `docs/release-checks/history.tsv`、`.github/codex-release-state.env`：自动化状态与历史记录。

## 构建、测试与开发命令

- `bash ./build-intel.sh /absolute/path/to/Codex.dmg`
  使用官方 DMG 构建 Intel 版 DMG 和 builder ZIP。
- `npm run build`
  `build-intel.sh` 的简易封装。
- `bash ./scripts/check-codex-release.sh`
  下载上游 DMG，检查版本和 sha，必要时发布 GitHub Release。
- `bash ./scripts/validate-release-updater.sh`
  对本地 build root 做 packaged/updater 验证。
- `node --check scripts/patch-codex-desktop.mjs && bash -n build-intel.sh`
  提交前的快速语法检查。

## 代码风格与命名约定

- Shell 脚本优先兼容 macOS 自带 `/bin/bash` 3.2，避免依赖新 Bash 特性。
- 多行块使用 2 空格缩进。
- 变量名保持显式，如 `RELEASE_DATE`、`GITHUB_RELEASE_REPO`、`TARGET_ARCH_LABEL`。
- 文件名保持职责清晰，例如 `check-codex-release.sh`、`patch-codex-desktop.mjs`、`codex-release-check.yml`。

## 测试指南

- 本仓库没有单元测试框架，验证以脚本和产物检查为主。
- 修改构建链路后至少运行：
  - `bash -n build-intel.sh`
  - `node --check scripts/patch-codex-desktop.mjs`
  - `bash ./scripts/validate-release-updater.sh`
- 修改自动化逻辑后，建议给 `STATE_FILE`、`HISTORY_FILE` 指向临时文件做 dry-run。

## 提交与 Pull Request 规范

- 提交信息遵循现有风格：`fix: ...`、`feat: ...`、`chore: ...`、`validate: ...`、`release: ...`。
- 每次提交只解决一个明确问题，避免把无关改动混在一起。
- PR 描述应写清：
  - 改了什么
  - 为什么改
  - 运行了哪些验证命令
  - 若涉及自动化，附上 workflow run 或 release 证据

## 安全与配置提示

- 不要硬编码密钥；优先使用 `GH_TOKEN`、`GITHUB_REPOSITORY`、`GITHUB_RELEASE_REPO`、`RELEASE_TARGET_REF` 等环境变量。
- `.github/codex-release-state.env` 属于运行状态文件，除非明确要重置自动化状态，否则不要手工改写。
