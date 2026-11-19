# 波 98 任务 A：来源页疑点块默认收起，任务详情去掉重复同步说法

## 背景

终核发现者证实，材料页剩余的杂乱主要来自疑点块。真实库 24 份材料共 201 条未解决转写疑点，单份最高 63 条。整块逐条展开并排在核心要点与待办之前，把「帮助/提醒」推到 2-3 屏之外。任务详情的提醒链路区把同一事实写了两遍：「已回读 · X」日期标签之后又紧跟一行「已同步提醒事项并回读」。

## 改动

- `Sources/VoiceOSApp/WorkspaceSourceView.swift:152-191` `UnresolvedIssuesBlock` 内加 `@State private var isExpanded=false`（`:159`）。摘要行改为按钮，保留「疑点 N · 核对未完成」warning 色与警告图标，右侧加折叠箭头（`chevron.down` 收起 / `chevron.up` 展开），并带「已展开 / 已收起」辅助功能值。收起时只渲染这一行。展开后才渲染原有逐条列表，每条的播放与跳到原文按钮不变。
- 两处调用点复用同一实现：正文区 `:601`，处理记录 `:806`。
- `Sources/VoiceOSApp/WorkspaceActivityViews.swift:449`（旧行号）删除 `Label("已同步提醒事项并回读", systemImage: "checkmark.circle")`。日期标签 `:431`「已回读 · X」保留。`:454-461` 的 `needsReview` 异常分支未动，异常可见性不受影响。

## 设计取舍

- 折叠状态放在 `UnresolvedIssuesBlock` 内部，用一个 `@State` 布尔。两处调用点各自独立，默认收起，不持久化。没有引入绑定或新的 fold 状态，避免把展示状态扩散到 `WorkspaceSourceView` 的 `SourceFoldState`。
- 摘要行沿用 `SourceFold` 的交互形状（整行按钮、`buttonStyle(.plain)`、`chevron.up/down`、`accessibilityValue`），读者不用学第二套折叠习惯。
- 删除任务详情的重复行是纯删除。该行只承载成功确认，不承载「需要核对」等异常；异常由 `needsReview` 分支自己的标签表达。

## 验证

- `swift build -j 2; echo build_exit=$?` → `build_exit=0`，日志 `Build complete! (142.12s)`。
- `swift test -j 2; echo test_exit=$?` → `test_exit=0`，`Executed 648 tests, with 0 failures`。任务书的 645 基线对应波 96 之前的 main；工作树基于含波 96 的 84cad40，已有 648 项，本波未加测试。
- 构建与测试都在两处改动的并集树上运行。提交一（来源页折叠）是其中一部分；活动页的一行删除在提交二落盘，内容与已验证的树一致。
- 构建与测试共用 `/tmp/voiceos-swift-build.lock`。测试收尾 `rmdir` 报锁目录已不存在，说明另一并发进程提前删除了锁；本轮构建与测试仍以真实退出码 0 完成，但同一时段的锁互斥不可靠，后续波次需复核清理归属。

## 遗留风险

- `.linked` 状态的成功提示在常规情况下由「已回读 · X」承担。若已链接的提醒事项没有任何可汇总字段（无到期日、无提醒、优先级为 0），`reminderObservedSummary` 为空，日期标签不渲染，删除重复行后该页不再有文字形式的「已同步」确认。此时「日期与提醒」按钮仍表明链接存在，提醒连接开启时 `reminderSyncStatus` 仍显示。风险低，未为这个边缘情况加回退行，以遵守本文件「仅删重复行」的所有权约束。
- 折叠状态不持久化，切换材料或视图重建后回到收起；这符合默认收起的诉求。
- 未加测试（纯视图层）。基线随 main 前移而变化：任务书写作时 main 含波 93-95、基线 645；实际工作树基于 84cad40（含波 96），其 TASK.md 记录 648 项 0 失败。
- 未重启应用，未写实时库，未 push，未合并 main。

## 文件所有权说明

- 只改 `Sources/VoiceOSApp/WorkspaceSourceView.swift` 与 `Sources/VoiceOSApp/WorkspaceActivityViews.swift`。未触碰其他文件。