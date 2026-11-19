# 波 93 任务 A：材料观点归属被主题整理调用遮蔽

## 背景

材料详情页看不到这份材料带来的提醒和帮助。协调者用真实数据库确认了根因。

`latestCandidateClaimsBySource` 按 `producer_sequence` 取每个来源最新一次完成调用，原先只排除 `english_feedback:%`。主题整理调用（`topic-reading-v2`、`topic-skeleton-v1`、`topic-body-v1`、`topic-skeleton-merge-v1`，schema `topics-v1`）也写 `model_attempts`，但从不写 claims。它们按多来源捆绑执行，完成更晚，于是把真正的观点提取调用（`organized_import`，`comprehensive-v1` 或 `expression-comprehensive-v5`，schema `claims-actions-v3`）遮住。实测 62 次主题调用全部 0 观点，54 次整理调用被遮住。

## 改动

- `Sources/VoiceOSCore/CognitiveStore.swift:270` 定义共享条件 `claimExtractionAttemptFilter`，排除 `english_feedback:%` 与四个 topic prompt_version。
- `Sources/VoiceOSCore/CognitiveStore.swift:280` `latestCandidateClaimsBySource` 复用该条件。
- `Sources/VoiceOSCore/CognitiveStore.swift:309` `latestCandidateClaims(for:)` 复用该条件。
- `Sources/VoiceOSCore/KnowledgeReview.swift:391` `knowledgeReviewClaimVersions` 复用该条件。
- `Sources/VoiceOSCore/Reflection.swift:83` `reflectionContents` 的 latestAttempt 查询复用该条件，保留原有 discussion provider 排除。

只追加 topic 排除，未改 schema，未加迁移。

## 测试

新增 `Tests/VoiceOSCoreTests/LatestClaimAttributionChecks.swift`，2 项。

- `:47` `latestCandidateClaimsBySource` 返回观点提取的 claims。
- `:55` `latestCandidateClaims(for:)` 同样返回。

构造方式：先 `importOrganizedClaims` 种一条 completed 观点提取调用（2 条 claims），再直接插入一条更晚的 completed 主题调用（`topic_skeleton` / `topic-skeleton-v1` / `topics-v1`，同一 context，`producer_sequence` 更大，无 claims）。

## 真实退出码

修复前（红）：

```
swift test -j 2 --filter LatestClaimAttributionChecks
Executed 2 tests, with 2 failures
test_exit=1
```

修复后（绿）：

```
build_exit=0
filtered_exit=0
Executed 2 tests, with 0 failures
test_exit=0
Executed 639 tests, with 0 failures
```

基线 637 项，本波新增 2 项。

## 验证边界

未改 schema，未加迁移。未写实时库，未重启应用。分支与提交未推送，未合并。
