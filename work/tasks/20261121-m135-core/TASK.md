# 135-A 核心标题/搜索的评审修复

依据代码评审确认的缺陷，只改标题与搜索链路及对应测试。

## 逐条

### 1. MaterialTitleText.normalizedGenerated 幂等且保护词内符号

- 修复：markdown 清理改为按行处理，只剥行首 `#`、`>`、`- ` / `* ` / `+ ` / 有序列表前缀，以及成对出现的 `**`、`` ` ``、`~~`；`#`、`_` 出现在词中时保留（C#、snake_case 不被破坏）。收紧时先记录尾部 `…` 与其它标点，超过 24 个 Character 才截断并重新补 `…`；尾部原有省略号保留一个，保证 `f(f(x)) == f(x)`。
- 测试：`MaterialTitleTextChecks` 新增 `testGeneratedTitleNormalizationIsIdempotent`、`testGeneratedTitleKeepsInWordSymbols`、`testTruncationEllipsisIsStable`。
- 未采纳：无。

### 2. generateRecordingTitles 成功计数诚实

- 修复：事务内只在 `savePresentation` 成功后累加 `savedCount`，返回实际写入数。被 `continue` 跳过的纯标点提案不计数，也不写 `responseIDs`，与原先跳过语义一致。
- 测试：`SearchIndexChecks.testGeneratedTitlesCountOnlySavedProposals`，一条有效提案 + 一条 `。。。`，断言返回 1、只存 1 条、无效来源没有 `automatic`。
- 调用点：签名不变，`VoiceOSApp.swift:171` 与 `VoiceOSCheck/Check.swift:53` 无需改动，消息自然显示实际保存数。
- 未采纳：无。

### 3. contentTitle 走收紧

- 修复：manual 分支返回 trim 后文本，全空白视为无并继续看 automatic；automatic 分支返回 `MaterialTitleText.normalizedGenerated` 结果，nil 视为无；`presentation.transcriptVersionID == transcriptVersionID` 的校验语义保持不变。
- 测试：`MaterialTitleTextChecks.testContentTitleTrimsManualAndNormalizesAutomatic` 直接断言 manual、automatic、版本过期三条路径。
- 未采纳：无。

### 4. 只读库校验转写版本

- 修复：`ReadOnlyLibrary.sourceRecord` 的查询补 `transcript_version_id`（取该来源最新转写）。automatic 标题仅在 `presentation.transcriptVersionID == 当前 transcript_version_id` 时采用，否则回退 `MaterialNaming.displayName(name)`；manual 不受版本限制。
- 测试：`ReadOnlyLibraryChecks.testAutomaticTitleRequiresMatchingTranscriptVersion` 覆盖版本一致、版本过期、manual 但版本过期三类。
- 说明：只读库仍不加载转写正文，正文派生回退继续替换为人间化名。
- 未采纳：无。

### 5. 索引标题单一来源、分组标题、防崩溃、去重复解码

- 修复：
  - 重建不再 `try sources()` 全量解码。材料标题所需字段直接来自同一条 SQL 行：`stored_name`、`kind`、`created_at`、`timezone`、`presentation_json`，正文仍用聚合转写；presentation 单遍解码。
  - 新增 Core 单一函数 `MaterialDisplayTitle.title(name:kind:createdAt:timeZone:presentation:transcript:transcriptVersionID:)`。`SourceRecord.displayTitle` 改为调用它；`expressedDate`、`recordingDateLabel` 一并下沉，行为保持（含自动标题的版本校验、录音日期、链接原文、正文派生和未命名类型回退）。SearchIndex 重建调用同一函数。
  - 分组标题：`presentation.expression` 存在、成员数大于 1、且有 manualTitle 或非空 title 时，材料行标题取 `expression.leadingDisplayTitle`，与 `WorkspaceView` 的 `expression.displayTitle(in:)` 使用同一判定；否则走上面的漏斗。
  - 防崩溃：原先 `Dictionary(uniqueKeysWithValues: try sources()...)` 在双 transcription job 下会因重复 source id 触发陷阱。重建路径不再调用 `sources()`，重复 job 不会进入唯一键初始化。这是移除触发点，而不是在重复出现后取第一条。
  - `stored_name` 仍写入 body，原文件名 / ISO 时间戳仍可搜；`searchIndexShape` 串未改。
- 测试：`SearchIndexChecks.testMaterialRowTitlePrefersGroupTitle`、`testDuplicateTranscriptionJobsDoNotBreakRebuild`；现有 SearchIndex 标题测试继续兜底。
- 未采纳：没有保留 `uniquingKeysWith` 兜底。重建已不构建按 id 的标题字典，专门保留一个字典只会重新引入全量映射。

### 6. MaterialNaming 缓存

- 修复：正则改为静态 `NSRegularExpression`；两个 `ISO8601DateFormatter` 静态复用；`DateFormatter` 按 `TimeZone.identifier` 存入 `NSCache`（线程安全），`.current` 与测试的显式时区共用同一路径。前缀表与 ISO 解析规则不变。
- 测试：现有 `MaterialNamingChecks` 的行为断言全部保留，未新增测试。
- 线程安全：`NSCache` 线程安全；`ISO8601DateFormatter` 在 macOS 上线程安全，且只在初始化后只读使用。
- 未采纳：无。

## 未采纳与风险

- 其它 `sources()` 全量 `Dictionary(uniqueKeysWithValues:)`（`prepareRecordingTitles`、`detachRecordingsFromExpressions`、`storedTranscriptionReviewFailures` 等）不在本次评审清单内，未改；双 transcription job 仍可能在这些路径触发同类陷阱。
- SearchIndex 的分组标题按评审要求只看 `presentation.expression` 的 manual / 非空 title，未复刻 `recordingExpression(in:)` 的成员 digest、版本与授权校验；过期分组标题可能留在索引里，直到下一次 dirty / fingerprint 触发重建。
- SearchIndex 用 `MAX(t.current_version_id)` 给重复 transcription job 选一个当前版本；应用列表在重复 job 下可能展开多行，而搜索索引每来源只有一行，版本选择是近似。
- 重建标题逻辑改变但 `searchIndexShape` 按评审要求保持不变；升级后已有索引不会仅因此重建，需等 dirty 或 fingerprint 变化。
- 按任务约束未运行 `swift build` / `swift test`；只对改动的 Swift 文件做了 `swiftc -frontend -parse` 语法解析，类型与运行时行为由主会话集成验证。