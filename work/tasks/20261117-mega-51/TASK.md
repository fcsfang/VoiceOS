# 波 51 任务书（2026-11-17，草案）

## 背景与证据

### 零观点材料（只读发现，证据在任务报告）
- FPGA 材料（C5DDBC78）整理器两次抽取 + 漏项复查均返回 `{"items": []}`，`intent_candidates` 仍写 `extracted_and_checked` + `full_transcript_coverage_checked: true`，表达置 completed，claims 0 条。整理目录见 `整理/连续表达/B48B173D…/…/001-C5DDBC78…/model-results-v3/ad7da124511575c9/01-extract.json`。
- 全库已保存、云端、有字材料 60 份，当前有效 claim 为零的 19 份：12 音频（3 份跑完整理仍 0、1 份未整理、8 份 claim 全冻结）、7 份文本生成物（不走整理器，不计）。
- 界面矛盾：首页与材料页按整段表达取观点并集，FPGA 单元 199 条，显示「已整理 · 原话可追溯」，掩盖该段零贡献（`RecentContent.swift:296`、`RecentContentHome.swift:374-375/:534-545`、`WorkspaceSourceView.swift:168-173/:213-216`）。
- 知识核查按单份 claim 守卫，该材料永远无法核查（`KnowledgeReviewView.swift:97-101`、`VoiceOSApp.swift:1911`、`:2139-2140`）。

### 长录音分段理解（静默失败审计第 1 条）
- 片段/聚合校验失败即 rejected，父批次终态，写死「不自动重发」：`SegmentExtraction.swift:118/:131-132`、`SegmentAggregation.swift:121/:133-134`。
- `SegmentedProcessingBatch.swift:69` 的 `revalidateRejectedSegmentAggregation` 全仓无调用者。
- 处理页只看转录 job_state（`WorkspaceProcessingView.swift:167`），「重新整理当前内容」复用同一批（`VoiceOSApp.swift:2341-2346`）。

## 产品判断（协调者已定）

零提取不判失败、不自动重跑（2 秒静音、8022 秒外部节目等合法零观点会无限重试）。改为可区分状态 + 人工出口：
- 条件：材料 origin=user、speaker=user、有实质文字（去空白后 ≥ 200 字符），整理完成且 0 条 located 引用。
- 状态落盘后，材料页与处理页显示「这段没有提取到想法」，给出「重新提取」（新命令号重跑该段）与「视为无观点」（清除标记、允许表达完成）。
- 表达完成条件不变（并集有 claim），但零提取标记未处理时，表达页显示提示条。

## 完成判据

1. 零提取标记：整理收纳端（`OrganizedPodcast.swift` 导入边界处）对满足条件的材料写入可查询状态；重启保留；记录位置需要 schema 迁移时从当时版本 +1 并幂等。
2. 材料页/处理页显示该状态与两个出口；「重新提取」走新命令号（不复用旧 commandID），「视为无观点」清除标记。
3. 长录音分段：片段/聚合的输出校验失败改为可重试分类（复用 RecordingFollowup conformance 的分类思路），处理页给「整批重试」入口，重试走新命令号；`revalidateRejectedSegmentAggregation` 若可用则接线，否则说明并删除死代码。
4. 测试：零提取标记写入/清除/表达完成阻断与放行；分段批次 rejected→重试成功；这两组均用隔离临时库。
5. `swift build -j 2` / `swift test -j 2` 真实退出码 0。

## 单元与文件所有权

### Unit ZC（零提取状态与出口）
- 文件：`Sources/VoiceOSCore/OrganizedPodcast.swift`、`Sources/VoiceOSCore/RecordingExpression.swift`、`Sources/VoiceOSCore/RecentContent.swift`（若需）、`Sources/VoiceOSApp/WorkspaceSourceView.swift`、`Sources/VoiceOSApp/VoiceOSApp.swift`（出口命令段）、对应测试。
- 独占 schema 迁移（ZC 唯一迁移写入者）。

### Unit UD（分段理解重试）
- 文件：`Sources/VoiceOSCore/SegmentExtraction.swift`、`Sources/VoiceOSCore/SegmentAggregation.swift`、`Sources/VoiceOSCore/SegmentedProcessingBatch.swift`、`Sources/VoiceOSApp/WorkspaceProcessingView.swift`、对应测试。
- 不改 OrganizedPodcast.swift / RecordingExpression.swift（ZC 独占）、不改 VoiceOSApp.swift（ZC 独占）。

## 集成

- 分支 `work/m51-zc`、`work/m51-ud` 从波 50 合并后的 main 切出；协调者合并 `work/mega-51`，单次构建 + 全量测试。
- 另候选（审计第 2-5 条，视波 50/51 成本取舍）：个人表达意图 rejected/unknown/blocked 的重试与忽略、录制处理请求 blocked 重评、提醒同步逐条捕获与原因落盘、待同步提醒失败原因显示。

## UD 结果（2026-11-17）

- adfeb26（核心）：`allowsExplicitRetry` 只在 `.rejected` 为真；片段/聚合校验失败原因写入「第 N 段 + 校验类别」；`retryRejectedSegmentedBatch` 用 `segmented-retry:<旧批次ID>:<序号>` 新命令号重建批次，旧批次保留；删除死代码 `revalidateRejectedSegmentAggregation`（同一不可变回执重查必然再失败，接入即假动作）。
- d4c3264（VoiceOSApp.swift）：`retrySegmentedBatch` 单函数新增，未改既有行。
- 8e3c9f7（处理页）：`workspaceSegmentedBatchFailures` 按来源取最新批次，并入 `workspaceNeedsAttention`，区块显示原因与「整批重试」，unknown 不可重试。
- 测试：SegmentedRetryChecks 三用例（rejected 可见与原因、新命令号重试成功且旧批次保留、超时 unknown 不重发）。
- 集成构建/测试结果补下方。
