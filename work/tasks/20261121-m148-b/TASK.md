# 148-B 播放轮询自适应与暂停评估快照收窄（WorkspaceSourceView / VoiceOSApp）

## 背景
性能发现：材料页打开期间 300ms 定时器常驻（暂停与不可播放时也轮询）；`evaluatePausedActionIDs` 每次调用读全量 workspace 快照（core+secondary+assistant+knowledge+validity+discussion），而它只用到 sources/claims/currentClaimsBySource/actions/ledgers。两条都是小而安全的降耗。

## 文件清单（只允许动这两个）
- Sources/VoiceOSApp/WorkspaceSourceView.swift
- Sources/VoiceOSApp/VoiceOSApp.swift

## 逐条

### 1. 播放位置轮询自适应（WorkspaceSourceView）
- 约 1155-1160 行 `.task { while !Task.isCancelled { refreshPlaybackPosition(); sleep(300ms) } }`：改为自适应间隔——`model.player?.timeControlStatus == .playing` 时保持 300ms；否则 1500ms（保住暂停时恢复播放的响应性，同时把空闲唤醒降到 1/5）。每次循环仍先 `refreshPlaybackPosition()`。
- 不改播放逻辑与 UI。

### 2. 暂停评估用 coreSecondary 快照（VoiceOSApp）
- 约 2757 行 `try? await store.workspaceSnapshot()` 改为 `try? await store.workspaceSnapshot(.coreSecondary)`。`WorkspaceActionPause.evaluate` 需要 sources/claims/currentClaimsBySource/actions/ledgers，均属 core/secondary 段；assistant/knowledge/validity/discussion 段与方法无关。
- 若阅读代码发现 evaluate 实际用到其它段（如 validity 或 discussion），改用满足需求的更小 scope 或在回报中说明并保持 .full。以代码证据为准。

## 约束
- 不改业务语义与文案；不改清单外文件。
- 不跑 swift build/test（波次批处理）；改动文件跑 `xcrun --sdk macosx swiftc -parse <files>`，真实退出码。
- 完成后在本工作树提交（不推送；任务书一并提交），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 回报
提交哈希、逐条完成情况与证据、parse 退出码、diff --stat。