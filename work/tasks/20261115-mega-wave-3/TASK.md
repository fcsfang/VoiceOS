---
status: done
started: 2026-11-15
updated: 2026-11-15
branch: work/mega-3
owner: coordinator
---

# 并行大波第三批

## 目标

五条互不重叠的线：本地重复任务、任务页重复与地点回读、实体索引、剪贴板历史、费曼式复述文字首版。同时收口第二批审查发现的缺陷。写入代理只写不编译，集成后单次编译与测试。

基线 `main` 为 `38472b3`，schema 59，224 项测试。

## 数据形状（schema 60，F0 独占）

```sql
CREATE TABLE action_recurrence (
  action_id TEXT PRIMARY KEY REFERENCES actions(id),
  series_id TEXT NOT NULL,
  period TEXT NOT NULL CHECK(period IN ('daily','weekly','biweekly','monthly')),
  created_at TEXT NOT NULL
);
CREATE INDEX action_recurrence_series ON action_recurrence(series_id);
CREATE TABLE source_entities (
  source_id TEXT NOT NULL REFERENCES sources(id),
  name TEXT NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('person','organization','term')),
  sentence_ids TEXT NOT NULL,
  mention_count INTEGER NOT NULL,
  PRIMARY KEY(source_id, name)
);
```

重复任务语义：`action_recurrence` 的一行钉在当前开放的这一次行动上。完成行动时在同一事务里删掉该行、按 period 从原到期日推进到未来的第一个周期点（月末按 Calendar 截断）、复制标题、来源、优先级与提醒时刻生成下一次行动，把行挂到新行动上。行不存在就只完成不生成后继；再次完成因行已删而不再生成，天然幂等。不映射 Apple 提醒事项的重复规则，下一次行动的提醒按现有排期路径写入。

实体索引：`NLTagger` 取人名与机构；术语取观点陈述里出现至少 2 次的名词短语（2 到 12 字）。每条存前三个出现的句子 id，只展示有原话依据的条目。

## 单元

### F0 数据库与重复任务、实体索引存储

文件：`Sources/VoiceOSCore/Database.swift`、`Sources/VoiceOSCore/Recurrence.swift`（新）、`Sources/VoiceOSCore/EntityIndex.swift`（新）、`Tests/VoiceOSCoreTests/RecurrenceChecks.swift`（新）、`Tests/VoiceOSCoreTests/EntityIndexChecks.swift`（新）、五处 schema 断言。

- `RecurrencePeriod` 四个值；`nextDue(after:period:calendar:)` 纯函数，月末截断，闰日按 2 月 28 日处理。
- 存储 API：`recurrence(actionID:)`、`setRecurrence(actionID:period:)`（行动须存在且未完成）、`clearRecurrence(actionID:)`。
- `completeActionWithRecurrence(id:)` 事务化完成并生成后继，返回后继 id 或 nil；应用侧完成路径改走它。
- 实体：`SourceEntity` 含 sourceID、name、kind、sentenceIDs、mentionCount；`entities(sourceID:)`；`replaceEntities(sourceID:entries:)` 先删后插。
- 测试覆盖周期推进、月末与闰日、完成两次只生成一个后继、清除后不再生成、实体先删后插、句子 id 截断到三处。

### F1 任务页重复与地点回读

文件：`Sources/VoiceOSApp/WorkspaceActivityViews.swift`、`Sources/VoiceOSPlatform/NativeReminders.swift`、`Tests/VoiceOSCoreTests/ReminderLocationChecks.swift`（新）。

- 任务页加「重复」选择：不重复、每天、每周、每两周、每月，显示当前周期，选择即写，未完成才可改。
- 重复任务标题旁显示重复徽标；完成后后继行动出现且带同一周期。
- NativeReminders 回读 `EKReminder.alarms` 里带 `structuredLocation` 的报警，任务页显示「到达某地时提醒」只读说明；纯格式化函数配测试。

### F2 实体索引阅读页

文件：`Sources/VoiceOSApp/WorkspaceSourceView.swift`。

- 材料页打开且无实体记录时后台生成并保存，失败不影响阅读页。
- 显示「人名与术语」区块，分人物、机构、术语三组，点条目跳到首个出现句子；无实体不显示区块。

### F3 费曼式复述（文字首版）

文件：`Sources/VoiceOSCore/FeynmanCompare.swift`（新）、`Sources/VoiceOSApp/FeynmanPractice.swift`（新）、`Sources/VoiceOSApp/ClaimNoteViews.swift`、`Tests/VoiceOSCoreTests/FeynmanCompareChecks.swift`（新）。

- 观点旁加「复述一遍」入口，弹窗隐藏原话，用户写下复述后提交，对照原话给出覆盖到的要点、遗漏词与可能含混处，只提示不打分，随时可展开原话核对。
- 对照为确定性词面覆盖（中文按相邻二字组，英文按小写词），纯函数可测；不做语义判断。

## 缺陷修复（G 单元，来自两轮只读审查）

### G1 导出包 v49

文件：`Sources/VoiceOSCore/PortablePackage.swift`、`Sources/VoiceOSCore/SourceAttachments.swift`、`Tests/VoiceOSCoreTests/PackageRoundTripChecks.swift`（新）。

- 包版本 49，导出表包含 schema 54 到 60 的全部用户数据表：澄清、专注、阅读状态、旁注、主题确认、抓取元数据、附件、子任务、时长、章节、模板，以及本批新增的重复与实体表。
- 附件原图与 PDF 登记进 `assets` 表并随包导出；替换附件时删除旧文件；读取上限 200MB。
- 恢复后逐表比对；旧的 48 包仍可导入，缺的表为空。

### G2 导入与启动校验可靠性

文件：`Sources/VoiceOSCore/Store.swift`、`Sources/VoiceOSCore/RecordingCapture.swift`、`Sources/VoiceOSPlatform/NativeMedia.swift`、`Tests/VoiceOSCoreTests/ImportRecoveryChecks.swift`（新）。

- `importedSourceID` 只返回 `saved` 或 `reference_only`；同一 commandID 命中 `interrupted` 行时走恢复，不再静默复用。
- `recover()` 对 `saved` 源不再逐文件解码：有 duration 的只核对大小与哈希记录，缺时才走 inspector。
- 启动校验失败先记录跳过，连续三次失败才隔离；`reverifySource(id:)` 提供恢复路径，成功后解除冻结。
- 口述封存中途失败后 `sealDictation` 接受 `sealed` 行续作，`interruptDictation` 兼容 `sealed`。
- 测试：interrupted 重试恢复、校验失败三次才隔离、sealed 续作。

### H3 应用接线层

文件：`Sources/VoiceOSApp/VoiceOSApp.swift`、`Sources/VoiceOSApp/FolderWatch.swift`、`Sources/VoiceOSCore/TextCapture.swift`、`Sources/VoiceOSCore/DatabaseBackup.swift`、`Sources/VoiceOSCore/MarkdownMirror.swift`、`Sources/VoiceOSPlatform/SpotlightIndexer.swift`、`Sources/VoiceOSPlatform/ClipboardHistory.swift`（新）、`Tests/VoiceOSCoreTests/ClipboardHistoryChecks.swift`（新）。

- 剪贴板历史：内存保留最近 20 条文本或 URL，菜单栏子菜单选择存入为材料，上下文写「剪贴板历史」。
- 抓取去重：剪贴板、服务菜单与 `voiceos://capture` 的 commandID 改为内容哈希加十分钟时间桶；同内容十分钟内重复触发返回已有材料并提示，不新建。
- 文件夹监听只在导入回调确认成功后写指纹，失败文件下轮扫描重试。
- Markdown 镜像与 Spotlight 更新移到后台任务；Spotlight 只提交变化项；镜像不删除文档（本波集成时已先去掉删除）。
- 备份结果发布到设置页状态：最近成功时间与失败原因，失败可重试。
- `interruptDictation` 兼容 `sealed`（与 G2 配套）。
- 测试：去重桶边界、剪贴板模型、备份状态记录。

## 集成顺序

F0 先合入，随后 G1、F1 到 F4、G2、H3。完成路径的接线（`changeAction` 完成时改走 `completeActionWithRecurrence`）由协调者在集成时处理，不放进 H3。第二批缺陷审查的修复按文件归属并入相应单元或由协调者直接修。

## 验证

- 单次 `swift build -j 2`，修完错误后单次 `swift test -j 2`。
- 实机用隔离副本：任务设为每周重复并完成后后继出现且到期正确；任务页显示重复与地点；材料页出现实体并可跳句；菜单栏剪贴板历史可存为材料；复述弹窗给出遗漏提示；导出再导入后子任务、章节、模板、旁注、附件齐全；文件夹监听里的坏文件下轮重试；备份失败在设置页可见。
- 取不到的项目写明原因。

## 已知边界

- 重复不映射 Apple 提醒事项的重复规则，提醒写在每一次的新行动上。
- 撤销一次重复任务的完成只恢复原行动，不收回已生成的下一次行动。
- 从 Apple 提醒事项的外部完成确认路径生成后继留到下一批；应用内完成（含已连接提醒事项的完成路径）会生成后继。
- 启动校验失败改为留错误不隔离，三次计数与界面恢复入口留到下一批。
- 实体索引只做单份材料，不做跨材料聚合与人工维护。
- 剪贴板历史只存内存，不记图片。
- 复述对照只做词面覆盖；录音复述与语义对照留到后续批次。
- 启动校验的「重新核对原件」入口本批只做存储方法，界面入口留到下一批。
- Apple 端侧模型候选因本机 `deviceNotEligible` 划掉，不再排期；App Intents 等工具链元数据处理可行，单独成批。

## 结果

2026-11-15 七个单元集成到 `work/mega-3`：F0 `8a06f85`，G1 `a760ce7`，F1 `a50c537`，F2 `760bc5d`，F3 `9cf2ecf`，G2 `f086631`，H3 `ec787ac`。集成修复 `e54ba42`。

`swift build -j 2` 修复八处集成错误后通过；`swift test -j 2` 262 项 0 失败（新增 Recurrence、EntityIndex、FeynmanCompare、ClipboardHistory、ImportRecovery、PackageRoundTrip、ReminderLocation 等 38 项）。

集成期修复：`SourceEntityKind` 与字符串比较导致的类型推断超时、复述组件参数遮蔽、镜像与 Spotlight 弱引用可选值、抓取去重的 actor await；完成路径接上后继生成（含提醒事项联动路径）且后继沿用 auto_send；启动校验失败改为留错误不隔离（两处既有测试同步更新）；设置页显示备份状态与重试；导出包 48 兼容守卫只拦新增 13 张表，往返测试夹具改用本人口述来源。

实机（隔离副本，实时库 sqlite 备份，起点 schema 59）：启动迁移到 60，`action_recurrence`、`source_entities` 与既有 `search_index`、`search_index_meta` 并存；新备份 283MB 且 `PRAGMA integrity_check` 为 ok，上一代备份保留；`Mirror/materials` 维持 78 份；索引在首次检索时重建。机器处于锁屏，窗口级核对不可得。

## 链接

- 2026-11-15 已合并为 `877a147`（PR #158）。
- `docs/product/reference-products.md` 第 9.3、9.4、9.5 节
- 2026-11-15 第二批任务卡 `work/tasks/20261115-mega-wave-2/TASK.md`
