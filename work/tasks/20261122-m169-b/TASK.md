# 169-B 死代码减法（删除 11 处无引用声明 + 残留 pyc）

## 背景
删除全景特性后做全仓死代码审计（grep 全 Sources+Tests 零引用，已由审计代理逐条给出 grep 证据）。本单元执行减法，只删代码、不改行为。

## 删除项（grep 证据见审计；删除前自行复核一次）
1. Sources/VoiceOSApp/AssistantExecutionView.swift：删除 `AssistantSheetSelection`、`AssistantDelegationView`、`AssistantExecutionView` 三个类型及其专用私有 `ExecutionCommand` enum。**保留** 文件内被引用的自由函数（如 assistantExecutionLabel）与其余仍用代码。
2. Sources/VoiceOSApp/ClaimReviewHistoryView.swift：整文件删除（唯一类型无引用；内联版本已在 WorkspaceSourceView）。
3. Sources/VoiceOSApp/RecordingFollowupView.swift：只删除 `RecordingFollowupSummary` struct；文件其余（RecordingFollowupView 等）保留。
4. Sources/VoiceOSCore/ReflectionReview.swift：只删除 `ReflectionReviewFollowup` enum。
5. Sources/VoiceOSCore/SearchIndex.swift：删除 `waitForPendingSearchRebuild(timeout:)`（从未接线；保留 typing rebuild 路径）。
6. Sources/VoiceOSApp/VoiceOSApp.swift：删除 `saveExpression`、`saveAndProcessExpression`、`chooseOrganizedResult`、`enrichReminderContexts` 四个函数（均零引用；若删除后其私有辅助函数也变为零引用，一并删除并在回报列出）。
7. Sources/VoiceOSCore/RecordingPresentation.swift：删除 `independent_reason` 属性（唯一读取方全景已删除；Codable 对未知键宽容，旧 JSON 解码安全；重新编码会丢弃该键——作为降级兼容缺口记录在回报）。删除后若 `TranscriptionReview.Correction` 的其它字段无影响，保持不动。
8. scripts/probes/__pycache__/chinese-retrieval-quality.cpython-314.pyc：删除该生成物（如 `scripts/probes` 目录因此为空则一并删除目录）。

## 保留（记录理由，不删除）
- docs/testing/fixtures/retrieval-quality-v1..v3.json、docs/research/**、docs/planning/vision-baseline.json：历史审计证据与文档存档，符合「记录不删」原则。
- .env.example 的 VOICEOS_PROBE_MODEL、development-guide 的 VOICEOS_TEST_CRASH_AT：文档/示例用途保留。
- scripts/perf/baseline.py：性能基线脚本，保留供人工使用。

## 验证
- 删除后全仓 `grep -rnw '<被删符号>' Sources Tests` 为 0（pyc/文档除外）。
- 每个被编辑 Swift 文件 `xcrun --sdk macosx swiftc -parse` 真实退出码 0；不跑 swift build/test。
- 完成后提交（不推送；任务书一并提交），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 回报
删除清单（文件、行数）、连带删除的私有辅助、独立残留 grep、parse 退出码、diff --stat（含净删行数）。