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
  - 只做离线验证，不引入新的发布资产或线上更新源

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
