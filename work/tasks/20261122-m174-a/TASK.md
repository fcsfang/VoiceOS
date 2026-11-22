# 174-A 首页行与阅读器显示笔记标题与预览

## 来源
产品文档第二阶段「记录与重访」与「其他页面也有信息展示问题」首页一行：首页与材料详情读同一段话，却换成另一套标题和摘要；首页右侧阅读器也应与材料详情的笔记标题一致，预览要能唤起记忆。

## 改动
- Core 新增批量查询 `VoiceOSStore.latestMaterialNotes(expressionKeys: [String]) -> [String: StoredMaterialNote]`。单条 SQL：
  `SELECT * FROM material_notes WHERE expression_key IN (?,…) ORDER BY created_at DESC, rowid DESC`。
  每个键取结果中最先出现的一行（即该键 created_at、rowid 最新的一版）；空数组不发查询、返回空字典。`materialNoteExpressionKey` 改为 public，供 App 用同一规范化口径构造键。
- 首页材料行与右侧阅读器共用笔记标题与摘要：
  - 标题回退链：笔记 `title`（去空白后非空）→ 现有 `item.title`。
  - 预览回退链：笔记导语 `lead` → 第一段首句（无句末标点或首句超 80 字时取前 80 字加「…」）→ 现有 `item.summary`（行为空时用第一条想法）。
  - 行与阅读器都走 `WorkspaceTitleFit.present`；行不新增操作。
- 表达式成员口径与 `MaterialNoteCenter.materialNoteMemberIDs` 一致：`sourcePageIndex.expression(for:)` 的 `sourceIDs` + `externalVersions` 键（排序、去重），再经 `materialNoteExpressionKey` 规范化；无有效表达式时回退单个 sourceID。
- 读取沿用代际缓存契约：`ControlCenter` 新增 `@Published private(set) materialNotesRevision`，笔记保存成功（`saveMaterialNote` 返回非 nil）时由 `materialNoteDidSave()` 自增。首页的任务键 `HomeMaterialNotesKey` = `recordsRevision` + `materialNotesRevision` + 可见材料行表达式键集合（去重排序）；`.task(id:)` 取消旧读，写回前重新计算键并比对，防止过期结果串写。
- 材料详情页、笔记生成与阅读页未改；无网络调用。

## 文件
- `Sources/VoiceOSCore/MaterialNote.swift`
- `Sources/VoiceOSApp/RecentContentHome.swift`
- `Sources/VoiceOSApp/VoiceOSApp.swift`（仅计数器与自增方法）
- `Sources/VoiceOSApp/MaterialNoteCenter.swift`（保存成功处一行推进计数器；任务文件范围未列此文件，但代际推进只能发生在保存路径）
- `work/tasks/20261122-m174-a/TASK.md`

## 验证
- 逐个 `xcrun --sdk macosx swiftc -parse`：MaterialNote.swift、RecentContentHome.swift、VoiceOSApp.swift、MaterialNoteCenter.swift 真实退出码均为 0。
- 按波次约定未跑 build/test；集成构建与上机核对由主会话统一执行。