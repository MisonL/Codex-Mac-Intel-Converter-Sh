# Codex App for Mac Intel (Unofficial)

## 项目状态

本项目已封版归档，不再继续维护或发布新版本。

原因很明确：截至 `2026-04-22`，OpenAI 已经提供官方 Mac Intel 版本，继续维护这个非官方转换仓库已经没有必要。

官方入口：

- [OpenAI Codex App](https://developers.openai.com/codex/app)

## 封版范围

- 停止自动检查上游版本
- 停止自动发布 GitHub Release
- 保留现有脚本、历史 release 和审查文档，作为历史参考

## 历史内容

仓库中保留的主要文件仍然可以用于复盘此前的非官方转换方案：

- `build-intel.sh`
  历史构建脚本，记录了此前从官方安装源转换 Intel 版的流程。
- `scripts/check-codex-release.sh`
  历史上游检测与发布脚本，现仅作为归档保留。
- `scripts/patch-codex-desktop.mjs`
  历史补丁脚本，记录了此前对 `app.asar` 更新逻辑的处理方式。
- `scripts/validate-release-updater.sh`
  历史验证脚本。
- `docs/reviews/`
  审查记录和验证结论。

## 上游说明

本仓库的 GitHub 上游项目 [Kvisaz/Codex-Mac-Intel-Converter-Sh](https://github.com/Kvisaz/Codex-Mac-Intel-Converter-Sh) 最近一次变更也已经明确写出：官方 Mac Intel 版已存在，因此这个非官方项目自然结束。

本仓库已吸收这一结论，并进入封版状态。
