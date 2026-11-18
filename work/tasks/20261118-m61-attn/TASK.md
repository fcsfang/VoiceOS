# 波 61 任务书（2026-11-18）：注意力计数正确性

## 背景（只读调查 2026-11-18）

侧栏「有 N 项需要查看」= `workspaceAttentionCount`（Sources/VoiceOSApp/WorkspaceProcessingView.swift:195-197）。实测 202 = 201 条转写疑点 + 1 个聚合布尔。两处计数失真：

1. 201 条转写疑点里只有 183 个不同 span_id：同一份 review 内重复 span 造成约 9% 虚高（9 个 span 重复，最多一个重复 5 次）。
2. 消息监测注意力「看过即消」：`markMonitorAttentionSeen`（Sources/VoiceOSApp/MonitorCenter.swift:619-622）在打开页面时写 seen 签名，即使最新报告仍是 failed/pending、实际问题（如未开云端授权）没解决，徽标也减 1。

## 完成判据

1. 转写疑点按 span_id 去重计数：`unresolvedTranscriptionIssueCount`（Sources/VoiceOSCore/RecordingPresentation.swift:89-91 相关路径）或计数调用点按 span_id 去重；处理页疑点列表展示同步去重（每条只出现一次）。真实库验证：201 → 约 183（同一脚本只读核对）。
2. 消息监测 seen 只在报告已解决后可写：最新报告 `state == complete` 且投递状态不为 failed 时，打开消息监测页才写 seen 签名；报告 failed/incomplete 或推送失败时打开页面不消除注意力。若报告随后变好，下一次打开页面写入 seen。
3. 其余注意力构成不变（转写疑点仍按 span 计、聚合布尔仍为布尔、主题整理仍布尔）。不改徽标其他分类，不改「行动」徽标。
4. 测试（新增 ≤3 个用例，隔离临时库）：同 span 重复 issue 去重后计数正确且列表不重复；failed 报告打开后 attention 仍为真；complete 且投递正常的报告打开后 attention 变假。中文断言消息。
5. `swift build -j 2` / `swift test -j 2` 真实退出码 0；当前 main 584 项测试。

## 文件所有权

- `Sources/VoiceOSCore/RecordingPresentation.swift`（去重或计数）
- `Sources/VoiceOSApp/WorkspaceProcessingView.swift`（计数调用与疑点行去重展示）
- `Sources/VoiceOSApp/MonitorCenter.swift`（seen 语义）
- 对应测试
- 不碰提醒同步（波 59 文件）、官网抓取（波 60 文件）、主题组织、全景、知识核查、分段理解。

## 约束

- 16GB：构建/测试共用 `/tmp/voiceos-swift-build.lock`。
- 绝不读写实时库（只读核对除外）；测试隔离临时库。
- 分支 `work/m61-attn`，提交回报；不 push、不合并、不重启应用；不加数据库迁移（span 去重在内存/展示层完成；确需持久化先停手说明）。

## 结果（2026-11-18）

- 分支：`work/m61-attn`，基线 `c7372b0`。
- 转写疑点去重：`SourceRecord.unresolvedTranscriptionIssues` 按 span_id 去重（同源同 span 只保留首条，保留首条 reason），`unresolvedTranscriptionIssueCount` 与处理页、来源页两处疑点列表共用这一路径。真实库只读核对：有效核对 50 份材料，原始 201 条疑点，去重后 183 条；重复 9 组（1 组 5 次、6 组 3 次、2 组 2 次），空 span 0 条。
- 消息监测 seen：新增 `MonitorAttention` 纯判定。`needsAttention` 只看最新报告是否已解决（`state == complete` 且 `deliveryState != failed`），旧版已写入的失败签名不会再压制注意力；`seenSignatureWhenOpened` 仅在已解决时返回签名，`markMonitorAttentionSeen` 直接采用，failed/incomplete/推送失败时打开页面不写 seen。
- 测试：`Tests/VoiceOSCoreTests/AttentionCountChecks.swift` 三例（临时库隔离，中文断言）：重复 span 去重计数且列表保留首条；failed/incomplete/推送失败报告打开后仍需注意；报告解决后打开才写入 seen 且注意力为假。
- 验证：`swift build -j 2` 退出码 0；`swift test -j 2` 退出码 0，Executed 587 tests, 0 failures（基线 584 + 新增 3）。
- 未改动：提醒同步、官网抓取、主题组织、全景、知识核查、分段理解；无数据库迁移；未 push、未合并、未动 dist、未重启应用。
- 遗留风险：真实库只有一份 `2026-11-18 failed/pending` 报告，`seen` 写入门槛的实机 UI 路径未驱动验证（纯函数与测试覆盖）；去重只作用于展示与计数层，数据库内的重复 issue 原样保留。
