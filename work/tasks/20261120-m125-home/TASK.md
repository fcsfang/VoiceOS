# 波 125-A：首页「结果待填」徽标收口

基线 `work/m125-home`（自 `main` @ 5f12eaf），工作树 `.worktrees/m125-home`。只改 `Sources/VoiceOSApp/RecentContentHome.swift`。目标：把全局「结果待填」计数从每条反馈行尾与阅读器头部收回到首页头部的常驻「每周回顾」按钮，消除同一全局数字挂在单行上的语义错误，并让 288pt 时间线列不再被行尾徽标挤压成两行。

## 改动

- `homeHeader`：`pendingOutcomeCount > 0` 时在「每周回顾」按钮文本后追加 `· N`（`palette.warning`），按钮保持 `.plain`；`help` 与 `accessibilityLabel` 在有待填时改为「N 项结果待填，打开每周回顾」。未新增组件，复用 `WorkspaceText.meta` token。
- 时间线行：`rowTrailing` 对 feedback 返回 nil，反馈行不再挂全局徽标；material 行仍显示「N 条待办」。
- 删除 `RowTrailing` 枚举：`.text` 的唯一生产者是反馈行徽标，行尾只剩「待办」一种形态，`rowTrailing` 直接返回 `String?`；`row` 与 `rowAccessibilityLabel` 的 `outcomeBadge` 参数一并删除。
- `timeline`：删除 `let pendingOutcomeBadge = outcomeBadge` 中转变量与 `return`。
- `feedbackReader`：移除标题旁的重复「结果待填」按钮及外卖层单元素 `HStack`（内部 `rows`/`count` 仍在用）。
- `outcomeBadge: String?` 改为 `pendingOutcomeCount: Int`，只服务头部 CTA；另加 `weeklyReviewHelp` 与 `weeklyReviewAccessibilityLabel` 两个字符串助手。
- 未改 `timelineWidth`（288pt），未碰其他文件。

## 验证

按波次约定未在本工作树运行 `swift build` / `swift test`，集成交由主会话统一构建。已完成静态核对：全文件 grep `outcomeBadge`、`pendingOutcomeBadge`、`RowTrailing` 无残留；`git diff --stat` 仅本文件。

## 风险

- 头部按钮由 `Button("每周回顾", systemImage:)` 改为 `Label` + `Text` 自定义标签，图标与文字间距依赖 `HStack(spacing: 4)`，实机需确认与原紧凑度一致。
- 反馈行不再提示待填结果，入口只剩头部按钮与每周回顾页；这是本波有意的收口，若实机发现可发现性不足再加提示。