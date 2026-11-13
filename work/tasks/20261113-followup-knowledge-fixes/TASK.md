---
status: open
started: 2026-11-13
updated: 2026-11-13
branch: work/followup-knowledge-fixes
pr: 136
owner: coordinator
---

# 跟进与知识核查的重试失败修复

## 目标

把实时库积压的「思想与目标跟进未完成」「知识核查未完成」全部重试，并修复重试过程中暴露的缺陷，让失败项能真正自愈，而不是反复卡在同一处。

## 决定

- 跟进链失败的主因是目标归属：生成出来的计划要求下一步沿用「同一目标」的未完成任务，而任务记录的 goalID 从来没有被写入过（521 条行动 0 条有值），校验必然失败。修法是按上一轮计划的步骤补出任务到目标的归属，并把校验放宽为「引用任务可以暂缺目标」。
- 模型返回的外部标识有时包含不存在的 id 或重复 id。边界处做归一：保留首次出现、丢弃未知项，不再让整步失败。跟进选择与知识核查候选同规则。
- 知识核查端口补上与跟进端口一致的瞬时状态重试（429/502/503/504，5 秒、15 秒退避），网关抖动不再直接记失败。

## 范围

- `Sources/VoiceOSCore/RecordingFollowup.swift`、`ResponsesRecordingFollowupPort.swift`：目标归属补全与选择归一。
- `Sources/VoiceOSCore/KnowledgeReview.swift`、`ResponsesKnowledgeReviewPort.swift`：候选归一与瞬时状态退避。
- `Tests/VoiceOSCoreTests/FollowupNormalizationChecks.swift`：6 项新测试（含「任务缺目标但被上轮计划引用」的真实失败链）。

## 验证

- `swift build -j 4` 通过；`swift test -j 4` 101 项 0 失败。
- 实时库副本重试（`/tmp/voiceos-fixcheck`，修复后构建）：跟进 40 条中完成 25→37，失败 13→1（余下一条为网络中断，可再重试）；知识核查完成 17→20（本轮仍在收尾）。
- 知识核查剩余失败已换为新类别，记录为后续问题：429 限流、模型输出不是约定 JSON（解码失败）、一次应用退出中断、一条候选缺少连续原话依据。本轮不宣称这些问题已修复。
- 未对实时库写入；验证全部在副本上。

## 链接

- 重试验证明细：`/tmp/voiceos-fixcheck` 数据库快照与 `/tmp/diag_followup.py` 诊断脚本（临时目录）。
- 相关任务：`work/tasks/20261113-action-review-resolution/TASK.md`（同轮重试时用户报告的待办卡死问题，独立分支）。

## 进展

- 2026-11-13 三项修复与测试完成；分支从 main 独立开出，测试 101 项 0 失败。
