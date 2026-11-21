# 137-A Core 侧补漏修复

目标：补漏扫描在 VoiceOSCore 发现的问题。范围限定 SearchIndex、ReadOnlyLibrary、RecordingPresentation 及对应测试；未运行 swift build/test，未写入实时资料库，未改 UI。

## 1. 分组标题的成员有效性校验

- 修复：搜索索引重建时，收集多成员 expression 的来源 id，用 `sourceRecords(ids:)` 一次取回成员（`uniquingKeysWith` 先到先得去重），直接复用 Core 的 `SourceRecord.recordingExpression(in:)`。只有分组仍有效才采用 `leadingDisplayTitle`，否则回退成员标题。
- 修复：材料 SELECT 补 `s.state`，并改为按 transcript 展开，标题版本选择与成员校验共用同一批行。
- 测试：`testMaterialRowTitleFallsBackWhenExpressionIsInvalid`（localOnly 成员使分组失效，标题回退到各成员正文）；`testMaterialRowTitlePrefersGroupTitleWhenExpressionIsValid`（成员与授权均有效，标题采用分组标题）。
- 未采纳：未把校验改写成纯 SQL 行判定。`needsTranscriptionReview` 依赖 spans、backend 与审核 JSON，复刻会与 Core 语义漂移，因此按任务要求直接调用现有函数。

## 2. 正文的 state 守卫

- 修复：只有 `state ∈ {saved, reference_only}` 的材料才把选中版本的正文传给 `MaterialDisplayTitle`；其他状态传 nil。聚合正文仍完整进入 body 供检索。
- 测试：`testTranscriptTitleRequiresExposedSourceState`（saved 用正文标题；interrupted 的正文仍可搜到，但标题为「未命名外部资料」）。
- 未采纳：无。

## 3. 重复 transcription job 的版本选择

- 修复：材料查询不再用 `MAX(t.current_version_id)` 加 `GROUP_CONCAT` 单行聚合，改为 `ORDER BY s.id, t.rowid` 展开，Swift 内按源分组。标题版本优先取「presentation.transcriptVersionID 匹配的最后一条 transcript」，无匹配取最后一条（最新 job）；body 仍拼接全部版本正文。输出仍是一条 source 一行。
- 测试：`testMaterialTitleUsesTranscriptVersionNamedByPresentation`（双 job，presentation 指向旧版本，新版 version id 字典序更大；标题采用旧版本的自动标题）。
- 未采纳：jobs 表没有 created_at，按任务允许的方式用 `t.rowid` 表示插入顺序；未改 `sources()` 本身在重复 job 下返回多行的行为。

## 4. generateRecordingTitles 的字典崩溃

- 修复：`prepareRecordingTitles` 先按来源 id 去重再筛选，policies 字典改用 uniquing；`generateRecordingTitles`、`detachRecordingsFromExpressions`、`storedTranscriptionReviewFailures` 改 `Dictionary(_:uniquingKeysWith:)`。
- 修复：全库其余 sources 派生字典统一同一写法：TaskInitiation、ReflectionQuestions、SourceExtractionFlag、ThoughtPanoramaStore、MaterialManagement、OrganizedPodcast、RecordingCorrectionContinuation、ConversationStore、ReflectionTopicFeedback、ReminderFields、RecordingFollowup、TopicOrganization、Reflection、RecordingContext、RecordingExpression。TopicOrganization 的候选目录在筛选后按 id 去重，避免重复 id 进入上下文准备。
- 测试：`testGenerateTitlesSurvivesDuplicateTranscriptionJobs`（双 job 来源下生成并保存 1 条标题，不崩溃）。
- 未采纳：未改 `sources()` 返回多行的根因，改动会影响所有视图，超出本波范围。`TopicOrganization.swift:861` 的字典来自 `input.context.sources`，该上下文在准备时已拒绝重复来源，不在此路径。

## 5. 只读库回退分支与 App 同源

- 修复：`ReadOnlyLibrary` 来源查询补 `s.timezone`。`displayTitle` 在无人间标题、也无版本匹配的自动标题时，audio/video 走新增的共享入口 `MaterialDisplayTitle.recordingFallbackTitle`（「录音 · 日期」）；其他类型仍人间化存储名。
- 测试：`testUnnamedAudioUsesRecordingDateInsteadOfStoredName`（audio 无标题，时区固定 Asia/Shanghai，期望「录音 · 11月1日 08:00」，并断言不再是人间化存储名）。
- 未采纳：未给只读库加载 transcript；空正文的标题回退仍不存在，和原边界一致。

## 验证与约束

- 按任务约束未运行 swift build/test，也未连接实时资料库。测试期望值时区与日期格式来自 `MaterialDisplayTitle`、`MaterialNaming` 的现有规则。
- 风险：`sourceRecords(ids:)` 在重复 job 的成员上仍可能返回多行，先到先得取决于行顺序；这类数据本就使 `sources()` 的版本字段有歧义，本波只保证不崩溃且与只读判定同源。