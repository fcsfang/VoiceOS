---
status: merge-ready
started: 2026-11-15
updated: 2026-11-15
branch: work/mega-2
owner: coordinator
---

# 并行大波第二批

## 目标

五条互不重叠的线。FTS5 全文检索、搜索界面与抓取模板、首次运行引导与统一撤销、播客章节、仅日期提醒的默认通知时刻。写入代理只写不编译，集成后单次编译与测试。

基线 `main` 为 `29ec4ad`，schema 58，202 项测试。

## 数据形状（schema 59，E0 独占）

```sql
CREATE VIRTUAL TABLE search_index USING fts5(kind UNINDEXED, ref_id UNINDEXED, title, body, tokenize='trigram');
CREATE TABLE search_index_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
```

迁移 58 到 59 先尝试 trigram，失败回退 unicode61；另建四个 UPDATE 触发器（sources、claims、actions、transcripts）写 `dirty` 标记，重建时清除。材料索引排除回收站。`SearchHit` 含 kind（material/claim/action）、refID、title、snippet。`search(query:limit:)` 用 MATCH，查询词转义后加引号；空查询返回空。`rebuildSearchIndexIfNeeded()` 用三类数据的行数与最大时间做指纹，写入 meta；`rebuildSearchIndex()` 清空重建材料标题与转写、观点陈述、行动标题与备注。五处 schema 断言从 58 改为 59。

## 单元

### E0 全文检索存储

文件：`Sources/VoiceOSCore/Database.swift`、`Sources/VoiceOSCore/SearchIndex.swift`（新）、`Tests/VoiceOSCoreTests/SearchIndexChecks.swift`（新）、五处 schema 断言。
测试覆盖中文与英文命中、重建后旧内容消失、空查询、无结果、指纹变化触发重建。

### E1 搜索界面与抓取模板

文件：`Sources/VoiceOSApp/WorkspaceView.swift`、`Sources/VoiceOSApp/TextCaptureView.swift`、`Sources/VoiceOSApp/SearchControls.swift`（新）。
- 搜索页改用 `model.searchAll(query)`（新扩展调用 E0 的 search），分组显示材料、观点、行动与片段，点结果跳到材料或任务；保留现有即时过滤作为空查询时的默认内容。
- 抓取页加「模板」菜单：应用模板把正文填入草稿，保存当前草稿为模板（弹窗命名），管理模板可删除。使用 schema 58 的 capture_templates 存储。

### E2 首次运行引导与统一撤销

文件：`Sources/VoiceOSApp/VoiceOSApp.swift`、`Sources/VoiceOSApp/Onboarding.swift`（新）、`Sources/VoiceOSApp/UndoSupport.swift`（新）、`Sources/VoiceOSCore/ActionUndoStack.swift`（新）、`Tests/VoiceOSCoreTests/ActionUndoStackChecks.swift`（新）。
- 引导：资料库就绪后首次显示三步引导（记录想法、资料与行动、快捷键），可跳过，完成或跳过写 UserDefaults，只显示一次。
- 撤销：行动完成、放下与重新打开可撤销，栈最多 10 步，⌘Z 触发，菜单栏加「撤销上一次行动变更」。Core 的 ActionUndoStack 纯逻辑配测试；App 侧在 changeAction 成功后入栈。

### E3 播客章节

文件：`Sources/VoiceOSApp/WorkspaceSourceView.swift`、`Sources/VoiceOSPlatform/MediaChapters.swift`（新）。
- MediaChapters 用 AVAsset 读取章节元数据组，返回标题与起点毫秒，最多 50 章，无章节返回空。
- 材料页首次打开时若没有已存章节，读取音频章节并写入 schema 58 的 source_chapters；显示「章节」列表，点章节从起点播放。文本材料不显示。

### E4 仅日期提醒的默认通知时刻

文件：`Sources/VoiceOSApp/ReminderSettingsView.swift`、`Sources/VoiceOSCore/ReminderFields.swift`、`Tests/VoiceOSCoreTests/ReminderDefaultAlertChecks.swift`（新）。
- 保存时若只有日期没有时刻且没有通知，自动补一条当天 09:00 的通知；已过 09:00 则顺延到次日 09:00。界面显示「仅日期任务默认在 09:00 通知」与实际通知时间。
- ReminderFields 提供纯函数 nextDefaultAlert(due:now:calendar:)，配测试。

## 验证

- 单次 `swift build -j 2`，修完错误后单次 `swift test -j 2`。
- 实机用隔离副本：搜索页输入中文与英文命中材料与行动；抓取页应用与保存模板；首次启动出现引导；完成任务后 ⌘Z 撤销；有章节的音频显示章节；仅日期保存后显示 09:00 通知。
- 取不到的项目写明原因。

## 已知边界

- 搜索索引是触发器式重建，不做增量。
- 撤销只覆盖行动状态，不覆盖改名、归档与删除。
- 章节依赖文件内嵌章节，不解析外部描述。
- 模板只作用于文字草稿。

## 结果

2026-11-15 五个单元集成到 `work/mega-2`：E0 `2800a6a`，E1 `93256fa`，E2 `0459190`、`42f8584`、`0eb3d5c`，E3 `48223fc`，E4 `e742ec8`。集成修复 `83e38dd`、`95ee8c4`。

`swift build -j 2` 一次通过；`swift test -j 2` 224 项 0 失败（新增 SearchIndex 9 项、ActionUndoStack 5 项、ReminderDefaultAlert 9 项）。

集成期修复两轮只读审查的当场项：两字查询 LIKE 回退与多词令牌 AND；脏标记触发器补齐行动备注、来源改名与转写版本变化后的索引刷新；回收站材料不进索引；撤销快捷键改 ⌥⌘Z 让出文本撤销；引导只对空资料库出现；模板覆盖非空草稿前确认；播放交错崩溃（代际令牌）、轮询只在值变化时写状态、结果草稿按行动 id 保留、每周回顾关闭后重取专注、提醒清单选择显示进度与错误、主题改名绑定目标、存为问题防重复提交；仅日期默认通知在逾期日期上顺延到下一个 09:00，语音提取与手动保存共用默认，设置页对仅日期任务不再显示会失效的通知开关；Markdown 镜像不再删除游离文档。

实机（隔离副本，实时库的 sqlite 备份，78 份材料、1051 条观点、523 条行动）：启动从 schema 54 连续迁移到 59，`search_index`、`search_index_meta` 与四个 `search_dirty_*` 触发器就位；`Backups/` 生成 271MB 备份且 `PRAGMA integrity_check` 为 ok；`Mirror/materials` 写出 78 份文档。机器处于锁屏（01:45），窗口级核对本轮不可得；副本只带数据库未带 assets，启动校验把 78 份材料全部隔离，这是副本缺口不是产品回归，但同时复现了「一次校验失败即永久隔离」的机制，已列入第三批 G2。

## 链接

- `docs/product/reference-products.md` 第 9.3、9.4、9.5 节
- 2026-11-15 第三批任务卡 `work/tasks/20261115-mega-wave-3/TASK.md`
