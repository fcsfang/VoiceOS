---
status: in_progress
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

迁移 58 到 59 先尝试 trigram，失败回退 unicode61。`SearchHit` 含 kind（material/claim/action）、refID、title、snippet。`search(query:limit:)` 用 MATCH，查询词转义后加引号；空查询返回空。`rebuildSearchIndexIfNeeded()` 用三类数据的行数与最大时间做指纹，写入 meta；`rebuildSearchIndex()` 清空重建材料标题与转写、观点陈述、行动标题与备注。五处 schema 断言从 58 改为 59。

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

## 链接

- `docs/product/reference-products.md` 第 9.3、9.4、9.5 节
