# 170-A 笔记末尾的「相关」轻入口

## 背景（产品文档第一阶段）
产品目标（原文）：我随口说出自己的想法，VoiceOS 帮我整理成一篇愿意重读的笔记。读完以后，我更清楚自己在想什么，也认得出这是我的意思。
文档「打开后的第一眼」中「读到末尾」一行：可以自然结束。有真实未解问题时留下问题，有明确行动时提供关联入口。讨论、修订、原文、技术处理状态按需进入，正文不再逐条重复「记录行动意图」。
169-D 已把材料详情做成正文式笔记阅读界面（`MaterialNoteReadingView`）。本单元只补读到最后时的轻入口，不改正文与既有折叠区。

## 必读
- `docs/product/VoiceOS 产品方向与开发交接：把口述整理成笔记.md`，重点「打开后的第一眼」的「读到末尾」。
- `Sources/VoiceOSApp/MaterialNoteReadingView.swift`（169-D 阅读界面）。
- `Sources/VoiceOSApp/WorkspaceSourceView.swift`：`actions`（`model.sourcePageIndex.actions(for:expressionIDs)`）、`loadedDiscussions`（`store.conversationsForSource(sourceID:)`）、`openTask`/`openDiscussion` 回调配线。

## 文件清单（只允许动这些）
- `Sources/VoiceOSApp/MaterialNoteReadingView.swift`（新增「相关」区与行原语）
- `Sources/VoiceOSApp/WorkspaceSourceView.swift`（仅接线传参）
- 新建 `work/tasks/20261122-m170-a/TASK.md`

## 数据来源与过滤（不新增查询 API）
- 行动：复用 `WorkspaceSourceView.actions`，即 `sourcePageIndex.actions(for:)` 按表达成员过滤出的现值，传入笔记视图后取 `validity == "current" && state == "open"`。已结束、已搁置、历史版本不进入末尾入口；下方「待办」「问题与目标」列表仍是完整清单。
- 讨论：复用页面已加载的 `loadedDiscussions`，取 `state == "active" && validity == "current"` 视为未结束。
- 「问题」类（`kind != "task"` 的当前行动）与待办同列，点击同样走 `openTask(id)`。

## 行为与视觉
- 位置：笔记正文最后一个 section 之后、共享左边线之内；`display == nil`（无笔记）时不出现。
- 标题「相关」：`caption` 字号、次要色；行：`meta` 字号、次要色，悬停转强调色，无卡框、无边框、无图标，行高与 meta/body 一致。
- 行动行：列出标题，点击 `openTask(id)`；最多列出 5 项，超出时以一行 caption 说明「还有 N 项在下方列表。」
- 讨论行：仅当存在未结束讨论时出现；1 段显示「继续这段讨论」，多段显示「继续最近一段讨论（还有 N 段没有结束）」，点击 `openDiscussion(最新一段.id)`。
- 空态：行动与讨论都没有时整块不渲染，正文读到末尾自然结束。
- 不改笔记正文、标题、元数据行与既有折叠区；不改 Core；不改首页。

## 约束
- 不跑 swift build/test；改动文件逐个 `xcrun --sdk macosx swiftc -parse` 真实退出码（不加管道）。
- 完成后在 worktree 分支提交（不推送；本文件一并提交），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。
- 回报：数据来源与过滤规则、空态行为、parse 退出码、diff --stat。