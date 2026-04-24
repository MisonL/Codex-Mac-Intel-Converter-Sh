# CSE Archive Decision 2026-04-24

## 结论

本仓库进入封版归档状态，不再继续维护。

## 触发原因

- OpenAI 已提供官方 Mac Intel 版 Codex App。
- 上游仓库 `Kvisaz/Codex-Mac-Intel-Converter-Sh` 最近一次更新也已明确声明该非官方项目应结束。
- 继续保留自动检测、自动发布和非官方转换链路，只会增加维护成本和误导风险。

## 本轮处置

- README 改为归档说明，明确项目停止维护。
- GitHub Actions 工作流改为手动触发的归档提示，不再执行上游检查或 release 发布。
- 保留现有脚本和历史文档，仅作为历史参考，不再作为持续交付链路。

## 边界

- 没有删除历史 release。
- 没有删除历史脚本。
- 没有尝试归档 GitHub 仓库设置；本轮仅处理仓库内容和自动化行为。
