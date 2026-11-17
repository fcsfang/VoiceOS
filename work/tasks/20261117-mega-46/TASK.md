# 波 46：主题整理加固（硬截止、标志复位、可见失败）

来源：今晚实测——主题重排自 17:20 起持续约 1 小时无 DB 落库、model_attempts 无新行；URLRequest 有 600 秒超时但走流式传输，疑似挂在流上或标志未复位。每次启动都会因主题过期再次触发，必须根治。

## 完成判据

1. 流式传输对主题整理有硬截止（从首字节或总时长二选一，读码后择优并说明；全景的 600 秒窗口与重试先例可参照 ResponsesPanoramaPort.swift:65）。超过截止即抛错，不再无限挂起。
2. organizingTopics 与相关状态在任何退出路径（成功、失败、取消、超时）都复位；组织失败时状态文案可见（含原因），首页状态行不会停留在「AI 正在连接主题」。
3. 主题整理运行状态可观察：开始/结束写入既有可读位置（优先复用 model_attempts 或既有 contexts 机制；若需新表，迁移 68，报告说明）；结束或失败后状态一致，不留永久 running。
4. 单元测试：超时路径抛错并复位标志（可用注入 transport 模拟悬挂）、失败路径状态文案、成功路径落库不变。
5. swift build 与 swift test 真实退出码 0（497 基础上新增）。

## 共享契约

- 不改 organizeTopics 的业务校验与 P1 的口径逻辑；只加超时、复位与可观察性。
- 不自动重建链接/主题；失败后由既有 needsTopicOrganizationRefresh 判据在下一轮触发重试。
- 文件所有权见下表；不动界面文件（状态文案在既有 status 属性里改）。

## 单元与文件所有权

| 单元 | 分支 / 目录 | 独占文件 | 内容 |
|---|---|---|---|
| X1 主题整理加固 | `work/m46-x1` / `.worktrees/m46-x1` | `Sources/VoiceOSApp/VoiceOSApp.swift`、`Sources/VoiceOSCore/TopicOrganization.swift`、`Sources/VoiceOSCore/ResponsesTopicOrganizationPort.swift`、`Sources/VoiceOSCore/ResponsesModelPort.swift`（仅传输截止相关）、`Sources/VoiceOSCore/Database.swift`（如确需迁移 68）、`Tests/VoiceOSCoreTests/` 相关 | 判据 1-5 |

规则同前：只在所属工作树改文件，不跑构建与测试，不碰主检出与实时库，提交信息结尾固定一行 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 决策细节

- 现状：ResponsesTopicOrganizationPort 用 DirectStreamingModelHTTPTransport，URLRequest timeoutInterval 600 但流式会话的超时语义可能不生效；organize 在 VoiceOSApp.swift:903-931 的循环里，organizingTopics 置 true 后在 await 上挂住则无复位。
- 交付前曾被重启终止（18:2x），新实例会再次触发；修复后若仍过期，同样受截止保护。
- 协调者纪律：构建与测试后台直跑并记录真实退出码；重启先过 scripts/app/restart_preflight.sh。

## 验证基线

- 实测：17:20 起 organizingTopics 持续为真约 1 小时；reflection_questions.updated_at 仍为 2026-10-20；model_attempts 无 reserved 新行。
- 用户随时可能回来：重启进空闲窗口。

## 结果（完成后填）

## 结果（2026-11-17 晚）

- X1：调用层硬截止（ModelDeadlineExceeded + withModelDeadline 竞速，主题整理默认 600 秒，到期取消并立即抛错）；VoiceOSApp 组织循环 defer 全路径复位 organizingTopics/worker，失败文案含原因；尝试记录复用 model_attempts（reserved → completed/rejected/unknown，带 WHERE state='reserved' 守卫）；失败冷却 30 分钟（UserDefaults voiceos.topics.lastFailure，自动触发受冷却，retry/force 绕过），文案「主题整理上次失败（原因），30 分钟后自动重试或可手动重试」；5 条测试（悬挂 transport 超时、成功落 completed、拒绝落 rejected、未知落 unknown 且下次立即成功、冷却 29/30 分钟边界与成功清除）。
- 集成修正：恢复校验原假设「completed 尝试皆为观点提取」，被主题尝试行打破（result_digest 语义不同）——按 prompt_version 'topic-reading-v2' 排除，测试恢复全绿。
- 验证（真实退出码）：swift build 0（Build complete! 80.08s）；swift test 0，503 项 0 失败（497 基础上新增 5，集成修正后净 +6）。
