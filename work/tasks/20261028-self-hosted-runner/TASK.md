---
status: in_progress
started: 2026-10-28
updated: 2026-10-28
branch: codex/self-hosted-runner-20261028
pr: -
owner: main session
---
# 自托管 Mac runner

## 目标

把 CI 从 GitHub 的共享 macOS runner 换到本机自托管 runner，去掉排队，用本地 CPU 跑测试。

## 范围

- 仓库改为私有，避免公开仓库的 fork PR 在 runner 上执行本机命令。
- 安装 actions runner v2.338.2 到 `~/actions-runner-voiceos`，作为 LaunchAgent 常驻。
- workflow 的 `runs-on` 改用 self-hosted 标签。
- CI 快慢分离：每次推送只跑 `swift build`，完整 `swift test` 用 `full-test` 标签或 main 推送。
- 首次运行验证 Swift 工具链和测试。

## 改动

- `.github/workflows/swift.yml` 的 `runs-on` 和 Swift 版本检查。
- 本机 runner 服务，不进仓库。

## 非目标

- 不改测试内容或产品代码。
- 不把 runner 用于公开仓库。

## 决策

- 仓库改私有，公开 Issue 不再对外可见；现有 Issue 保留。
- 用 LaunchAgent 常驻，Mac 登录后自动上线。
- 用具体标签 `self-hosted, macOS, ARM64, voiceos-local`，避免误用其他 runner。
- 完整测试不再阻塞每次推送。日常迭代用 `swift build` 和真实应用，完整测试按需运行。

## 当前状态

runner 在线。第一次完整测试正在跑。workflow 已改为每次推送只跑 `swift build`，完整测试用 `full-test` 标签或 main 推送。

## 下一步

第一次完整测试结束后推送新 workflow，更新分支保护为 `build`，给本 PR 加 `full-test` 标签验证完整测试。

## 验证

- runner API 显示 online，labels 正确。
- PR 的 CI job 在 self-hosted runner 上跑完 `swift test -j 4`。
- 对比之前 11 分 34 秒的托管 runner 时间。

## 链接

- Runner 目录: `~/actions-runner-voiceos`
- 服务: `actions.runner.fcsfang-VoiceOS.voiceos-mac`
- PR: 待开
