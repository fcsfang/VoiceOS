# 167-C 行动/工作区/首页测试套件缩减（10 个文件）

## 背景
同 167-A。只允许表驱动折叠与有引证的重复删除；生产代码零改动。禁止碰 Reminder*/Package/Storage/ImportRecovery 等安全套件。

## 文件清单（只允许动这些）
- Tests/VoiceOSCoreTests/ActionRowStatusChecks.swift
- Tests/VoiceOSCoreTests/RecurrenceChecks.swift
- Tests/VoiceOSCoreTests/ExternalActionCommandChecks.swift
- Tests/VoiceOSCoreTests/ExternalCompletionChecks.swift
- Tests/VoiceOSCoreTests/ActionUndoStackChecks.swift
- Tests/VoiceOSCoreTests/RetryResilienceChecks.swift
- Tests/VoiceOSCoreTests/PromoteActionChecks.swift
- Tests/VoiceOSCoreTests/ActionReviewResolutionChecks.swift
- Tests/VoiceOSCoreTests/RecentContentDigestChecks.swift
- Tests/VoiceOSCoreTests/RecentContentHomeSnapshotChecks.swift
- Tests/VoiceOSCoreTests/RecentClueOverrideChecks.swift
- Tests/VoiceOSCoreTests/FollowupDigestChecks.swift
- Tests/VoiceOSCoreTests/FollowupSuggestionChecks.swift

## 目标
- 测试函数总数减少 ≥25%，覆盖不降。
- 优先点：ActionRowStatus 的逐状态矩阵表驱动化；External Action/Completion/Undo 三套件对同一命令生命周期的重复路径合并；RecentContent 三套件对同一快照结构的重复断言合并；Followup 两套件的建议规则矩阵表驱动。

## 验证
- 每个改动文件 `xcrun --sdk macosx swiftc -parse` 退出码 0；不跑 swift test。
- 回报：前后函数计数、折叠形态、删除项对应测试名、parse 退出码、diff --stat。