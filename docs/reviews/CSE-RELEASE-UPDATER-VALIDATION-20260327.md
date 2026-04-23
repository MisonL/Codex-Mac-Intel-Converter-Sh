# CSE Release Updater Validation 2026-03-27

## Control Contract

- Primary Setpoint: 用最小实验证明当前 Intel 转换产物为什么被识别为 dev build，以及自动更新链路是否被 Sparkle 原生模块阻断。
- Acceptance:
  - 证明默认 `Electron.app` 壳下 `app.isPackaged` 仍为 `false`
  - 证明重命名壳和主可执行文件后 `app.isPackaged` 可变为 `true`
  - 证明当前 Intel 转换产物缺失 `sparkle.node`
- Guardrail Metrics:
  - 不修改 `main` 已发布 release
  - 不用推测替代代码证据和实验结果
- Boundary:
  - 初始阶段只做离线验证
  - 后续追加一次受控的 GitHub Actions 线上验证，但不在验证分支发正式 release

## Plant / Sensors / Error

- Plant:
  - [build-intel.sh](/Volumes/Work/code/Codex-Mac-Intel-Converter-Sh/build-intel.sh)
  - 官方 `Codex.app` 的 `app.asar`
  - 当前 Intel 转换产物
- Sensors:
  - `file`
  - `PlistBuddy`
  - 最小 Electron 运行实验
- Error:
  - 参考目标是“release 态 + 可用更新链路”
  - 实际输出是“`app.isPackaged=false` + Sparkle 被移除”

## Findings

1. 当前脚本保留了默认 Electron 壳，因此 release 态误差真实存在。
   - [build-intel.sh](/Volumes/Work/code/Codex-Mac-Intel-Converter-Sh/build-intel.sh#L261) 到 [build-intel.sh](/Volumes/Work/code/Codex-Mac-Intel-Converter-Sh/build-intel.sh#L272) 直接复制 `Electron.app`，并把 `CFBundleExecutable` 设为 `Electron`。
   - 最小实验表明：即使 `Contents/Resources/app` 中有正式应用，只要壳和主可执行文件仍是默认 Electron 命名，`app.isPackaged` 仍为 `false`。

2. 让 `app.isPackaged=true` 的最小必要条件之一，是重命名壳和主可执行文件。
   - 离线实验中：
     - 默认壳 `Electron.app/Contents/MacOS/Electron` => `isPackaged: false`
     - 重命名为 `Codex.app/Contents/MacOS/Codex`，并同步 `CFBundleExecutable` => `isPackaged: true`
   - 这说明当前问题不只是 renderer URL，而是打包壳本身仍被 Electron 识别为默认开发壳。

3. 当前自动更新链路被硬切断，不是仅靠替换 feed URL 就能恢复。
   - 官方包里的 Sparkle feed 配置存在，见 [.tmp/asar_inspect/package.json](/Volumes/Work/code/Codex-Mac-Intel-Converter-Sh/.tmp/asar_inspect/package.json#L89) 到 [.tmp/asar_inspect/package.json](/Volumes/Work/code/Codex-Mac-Intel-Converter-Sh/.tmp/asar_inspect/package.json#L91)
   - 当前脚本会直接删除 Sparkle 原生模块，见 [build-intel.sh](/Volumes/Work/code/Codex-Mac-Intel-Converter-Sh/build-intel.sh#L317) 到 [build-intel.sh](/Volumes/Work/code/Codex-Mac-Intel-Converter-Sh/build-intel.sh#L320)
   - 实测官方 `sparkle.node` 为 `arm64`，而 Intel 转换产物中该文件缺失

## Validation Commands

```bash
./scripts/validate-release-updater.sh
```

## CSE Conclusion

- 主误差 1: 当前转换流程没有形成真正的 release 壳
- 主误差 2: Sparkle 更新执行器被移除，控制链路中断
- 因此“把更新链接改到 GitHub Release”不是当前一阶控制输入
- 正确的下一层控制输入应是：
  - 先把 Intel 转换产物重构为真正 packaged 的 `Codex.app`
  - 再决定是否补回 x64 Sparkle 原生模块和 appcast 发布链路

## Implementation Validation

1. 已把 Intel 转换流程切到 packaged 壳，并把更新源切到 GitHub Release。
   - [build-intel.sh](/Volumes/Work/code/Codex-Mac-Intel-Converter-Sh/build-intel.sh#L305) 到 [build-intel.sh](/Volumes/Work/code/Codex-Mac-Intel-Converter-Sh/build-intel.sh#L334) 会把 Electron x64 runtime 重命名成 `Codex.app/Contents/MacOS/Codex`，同步重命名 helper app，并在 `app.asar` 内注入 GitHub release updater 元数据和逻辑。
   - [scripts/patch-codex-desktop.mjs](/Volumes/Work/code/Codex-Mac-Intel-Converter-Sh/scripts/patch-codex-desktop.mjs#L98) 到 [scripts/patch-codex-desktop.mjs](/Volumes/Work/code/Codex-Mac-Intel-Converter-Sh/scripts/patch-codex-desktop.mjs#L206) 会：
     - 把 `"Install Update"` 改成 `"Download Update"`
     - 向 `package.json` 注入 `codexIntelReleaseRepo`、`codexIntelReleaseTag`、`codexIntelReleaseDate`、`codexIntelAssetName`、`codexIntelArch`
     - 按 bundle 特征自动识别旧版 `deeplinks-*.js` 和新版 `product-name-*.js`
     - 用 GitHub latest release 查询逻辑替换原 Sparkle native updater 方法段

2. 已修正两个真实实现缺陷。
   - `deeplinks` 补丁边界原本截到 `resolveIntervalMs()`，会生成重复方法定义，导致主进程 JS 语法损坏；现在改为截到 `buildDiagnostics()` 前。
   - [build-intel.sh](/Volumes/Work/code/Codex-Mac-Intel-Converter-Sh/build-intel.sh#L175) 到 [build-intel.sh](/Volumes/Work/code/Codex-Mac-Intel-Converter-Sh/build-intel.sh#L182) 去掉了 `mapfile`，改成 Bash 3.2 兼容写法，避免 macOS 默认 `/bin/bash` 直接失败。
   - [scripts/check-codex-release.sh](/Volumes/Work/code/Codex-Mac-Intel-Converter-Sh/scripts/check-codex-release.sh#L112) 到 [scripts/check-codex-release.sh](/Volumes/Work/code/Codex-Mac-Intel-Converter-Sh/scripts/check-codex-release.sh#L126) 已修正已有 release 查询的 stdin 覆盖问题，避免状态文件缺失时错误重发 release。

3. 2026-03-27 当次构建和验证已通过。
   - 验证结果：
     - `node --check` 通过：
       - `bootstrap.js`
       - `deeplinks-D8FzxbSB.js`
     - `package.json` 中已写入：
       - `codexBuildFlavor=prod`
       - `codexIntelReleaseRepo=MisonL/Codex-Mac-Intel-Converter-Sh`
       - `codexIntelReleaseTag=v26.324.21641-x64-20260327`
       - `codexIntelAssetName=CodexAppMacIntel_26.324.21641_x64_20260327.dmg`
     - helper app 名称和主可执行文件名已对齐 `Codex`
     - `BUILD_ROOT=/Volumes/Work/code/Codex-Mac-Intel-Converter-Sh/.tmp/codex_intel_build_20260327_200842 ./scripts/validate-release-updater.sh` 输出：
       - 默认 `Electron` 壳 => `isPackaged: false`
       - 重命名 `Codex` 壳 => `isPackaged: true`

4. 同日已完成对最新上游版本和 GitHub Actions 的追加验证。
   - 最新实测上游版本：`26.325.21211`
   - 结果：
     - 新版上游 `app.asar` 不再包含 `deeplinks-*.js`，而是把 updater 逻辑收敛到 `product-name-*.js`
     - 当前补丁器已能同时兼容旧版和新版结构
     - `node --check` 已通过新版工作目录里的 `.vite/build/*.js`

5. GitHub Actions 真实跑通。
   - 工作流文件：
     - [.github/workflows/codex-release-check.yml](/Volumes/Work/code/Codex-Mac-Intel-Converter-Sh/.github/workflows/codex-release-check.yml)
   - 当前调度：
     - 每天 `09:00` `Asia/Shanghai`，在 GitHub Actions cron 中对应 `01:00` `UTC`
   - 运行前提：
     - 显式设置 `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24=true`，避免 JavaScript actions 的 Node 20 弃用警告
   - 真实运行：
     - Run ID: `23646890570`
     - Conclusion: `success`
   - 说明：
     - 这次运行仅用于验证 workflow 能成功完成
     - 合入 `main` 前已移除验证分支专用 `push` 触发和种子状态
