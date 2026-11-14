---
status: merge-ready
started: 2026-11-14
updated: 2026-11-14
branch: work/mega-1
owner: coordinator
---

# 并行大波（9.3 到 9.5 核心）

## 目标

一次推进六条互不重叠的线：数据库 58 与存储、行动页安排与键盘、任务页子任务与时长、阅读页大纲与逐层、每周回顾向前选、横向机制（Spotlight、备份、Markdown 镜像）。所有代理只写不编译，集成后单次 `swift build -j 2` 与 `swift test -j 2`。

基线 `main` 为 `e068013`，schema 57，191 项测试。

## 数据形状（schema 58，D0 独占）

```sql
CREATE TABLE action_subtasks (
  id TEXT PRIMARY KEY,
  action_id TEXT NOT NULL REFERENCES actions(id),
  title TEXT NOT NULL,
  done INTEGER NOT NULL DEFAULT 0,
  ordinal INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  completed_at TEXT
);
CREATE INDEX action_subtask_action ON action_subtasks(action_id, ordinal);
CREATE TABLE action_estimates (
  action_id TEXT PRIMARY KEY REFERENCES actions(id),
  minutes INTEGER NOT NULL CHECK(minutes IN (15,30,60)),
  updated_at TEXT NOT NULL
);
CREATE TABLE source_chapters (
  source_id TEXT NOT NULL REFERENCES sources(id),
  ordinal INTEGER NOT NULL,
  title TEXT NOT NULL,
  start_ms INTEGER NOT NULL,
  PRIMARY KEY(source_id, ordinal)
);
CREATE TABLE capture_templates (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  body TEXT NOT NULL,
  created_at TEXT NOT NULL
);
```

存储 API（D0 实现，其他单元按此调用）：
- `ActionSubtask` 含 id、actionID、title、done、ordinal、createdAt、completedAt。`subtasks(actionID:)` 按 ordinal；`addSubtask(actionID:title:)`（去空白 1 到 200 字，行动须存在）；`setSubtaskDone(id:done:)`；`deleteSubtask(id:)`。
- `actionEstimates() -> [String:Int]`；`setActionEstimate(actionID:minutes:)` 只收 15、30、60；`clearActionEstimate(actionID:)`。
- `SourceChapter` 含 sourceID、ordinal、title、startMS。`chapters(sourceID:)` 按 ordinal；`replaceChapters(sourceID:entries:)` 先删后插，条目按 startMS 排序重编号。
- `CaptureTemplate` 含 id、name、body、createdAt。`captureTemplates()`、`saveCaptureTemplate(name:body:)`（名称唯一，1 到 40 字）、`deleteCaptureTemplate(id:)`。
- 五处 schema 断言从 57 改为 58。

## 单元

### D0 数据库与存储

文件：`Sources/VoiceOSCore/Database.swift`、`Sources/VoiceOSCore/ActionSubtasks.swift`、`ActionEstimates.swift`、`SourceChapters.swift`、`CaptureTemplates.swift`（均新）、`Tests/VoiceOSCoreTests/MegaStorageChecks.swift`（新）、五处 schema 断言。

### D1 行动页安排与键盘

文件：`Sources/VoiceOSApp/WorkspaceView.swift`。

- 安排今天：我的待办头部加「安排今天」，弹窗列出即将与随时的开放任务，最多选 3 条，确认后加入专注（`toggleActionFocus`）。超限给提示。
- 键盘处理：行动页获得焦点时，上下键移动高亮行，Return 打开，X 标记完成，Z 不再跟进。输入框聚焦时全部让开。
- 迁移决策：我的待办里逾期任务单列「逾期」小组，行内给「改天」「移到随时」「不再跟进」。改天复用现有提醒设置入口，没有提醒链接时禁用并提示。移到随时只把行动移出专注，不写外部排期。

### D2 任务页子任务与预计时长

文件：`Sources/VoiceOSApp/WorkspaceActivityViews.swift`。

- 任务页新增「子任务」区块：列表勾选、添加、删除，显示完成比。存储走 D0。
- 任务页新增「预计时长」选择 15、30、60 分钟与清除，显示在任务头部。存储走 D0。

### D3 阅读页大纲与逐层

文件：`Sources/VoiceOSApp/WorkspaceSourceView.swift`、`Sources/VoiceOSApp/ReadingLayers.swift`（新）。

- 逐字稿大纲：按 span 时间间隔超过 20 秒切成小节，标题取该节首段前 24 字，点击从该节起点播放。最多 20 节。
- 音文同步：原话片段的文字可点，点击从该片段起点播放，与现有逐句高亮共用播放器。
- 渐进式摘要：在观点列表上方加「逐层读」，三层为原文摘录、要点（各观点首句）、一句话（现有整体摘要首句），默认收起，只做可回溯展示，不新增模型调用。

### D4 每周回顾向前选

文件：`Sources/VoiceOSApp/WeeklyReviewView.swift`。

- 新增「下周先做」区块，从随时与即将里多选最多 3 条，确认后加入专注（`toggleActionFocus`）。已有专注在前，超限提示。
- 不改今天收尾与其余区块。

### D5 横向机制

文件：`Sources/VoiceOSApp/VoiceOSApp.swift`、`Sources/VoiceOSPlatform/SpotlightIndexer.swift`（新）、`Sources/VoiceOSCore/DatabaseBackup.swift`（新）、`Sources/VoiceOSCore/MarkdownMirror.swift`（新）、`Tests/VoiceOSCoreTests/CrossCuttingChecks.swift`（新）。

- CoreSpotlight：刷新后把材料标题与转写摘录、观点陈述、开放行动索引到系统搜索，去重与节流，失败不影响主流程。
- 数据库快照备份：应用启动并恢复完成后，把资料库复制到 `Backups/`，用 `PRAGMA integrity_check` 验证，保留最近 7 代，文件名带时间。只读复制，不改实时库。
- Markdown 镜像：把材料、观点与行动写成带 front matter 的 Markdown 到 `Mirror/`，每次刷新节流写一次，失败不打断刷新。
- 测试：备份文件生成与完整性、Markdown 内容与转义。Spotlight 不做自动化测试。

## 集成顺序

D0 先合入根分支，随后 D1 到 D5。D1、D2、D3、D4 依赖 D0 的 API 契约，按任务卡签名写，不改数据库。

## 验证

- 单次 `swift build -j 2`，修完错误后单次 `swift test -j 2`。
- 实机用隔离副本：安排今天最多三条、行动页键盘上下与 Return、任务页子任务与时长、阅读页大纲点击播放与逐层读、每周回顾向前选、Spotlight 索引与备份目录生成。
- 取不到的项目写明原因。

## 已知边界

- 迁移决策不做推迟次数统计，外部排期仍走提醒事项。
- 逐字稿大纲按时间间隔切，不是语义章节。
- Markdown 镜像是单向导出，不反向导入。
- Spotlight 与备份不做界面管理入口。

## 结果

2026-11-15 六个单元集成到 `work/mega-1`。D0 `d5f262d`，D1 `5c9d9fb`，D2 `9db3a52`，D3 `eb9c197`，D4 `6c24ef5`，D5 `0cd7041`。

`swift build -j 2` 通过，`swift test -j 2` 202 项 0 失败。新增存储、备份、镜像与逐层读的测试。

实机：隔离副本 schema 58，四张新表存在；启动后 `Backups/` 生成带时间的备份，`PRAGMA integrity_check` 为 ok；`Mirror/` 建立 materials、claims、actions 三个目录。界面点击在本机双实例环境里没有落到测试实例，安排今天、子任务与时长、大纲与逐层、向前选、Spotlight 搜索没有实机核对，由存储测试与代码审查覆盖。

## 链接

- `docs/product/reference-products.md` 第 9.3、9.4、9.5 节
