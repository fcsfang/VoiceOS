# 132-A 主题页线索与未归组材料区块对齐同页规范

## 背景

主题详情「材料」页签用 `WorkspaceSection` 呈现内容（图标、标题、计数、发丝线），但同页列表的「线索」折叠区与「尚未归入主题的材料」折叠区仍是自绘标题：计数拼在标题括号里，标题用次级色，标题下没有发丝线。未归组材料展开后的行之间也没有分隔线。同一页的两种区块读起来像两个页面。

## 改法

只动 `Sources/VoiceOSApp/WorkspaceView.swift` 的 `themes` 属性，约 :1107-1150。

- 两个折叠区的 label 改为 `VStack(alignment:.leading,spacing:0)`：`WorkspaceSectionHeading` 加 `.padding(.bottom,16)`，下接 `WorkspaceListDivider()`。与 `WorkspaceSection` 的头部节奏一致（标题、16、发丝线）。
- 「线索」标题从 `线索（N）` 改为 `WorkspaceSectionHeading("线索", count:"N")`，计数改为独立的等宽数字，颜色走组件的三级文字。
- 「尚未归入主题的材料」标题同理。「交给 AI 归组」按钮移入 `WorkspaceSectionHeading` 的 trailing，按钮文案、动作、`disabled`、`help` 原样保留。
- 保留 `DisclosureGroup` 与原有绑定（`showingClues || !filter.isEmpty`），展开/收起行为不变。「尚未归入主题的材料」仍为系统默认的收起状态。
- 「线索」行间隔线由 `Divider()` 换成 `WorkspaceListDivider()`。未归组材料行间补同样的条件分隔线，仅行间，末行后不加。展开内容包进 `VStack(spacing:0)` 并加 `.padding(.top,8)`，与「线索」一致。
- 未归组材料的行集合先取 `let expressions=distinctExpressions(unlinked)`，`ForEach` 与末行判断共用，避免每行重算。

选型：`WorkspaceListSection(collapsible:)` 自带标题、发丝线与行容器，但没有 trailing 按钮位，展开状态又是组件内部的 `@State`，无法保留 `filter` 强制展开与 `showingClues` 的现有交互。改 `DisclosureGroup` 的 label 内容是最小改动，视觉与其他区块同构。

## 验证

- `xcrun swiftc -parse Sources/VoiceOSApp/WorkspaceView.swift` 退出码 0。
- `git diff --check` 退出码 0。工作区只有 `WorkspaceView.swift` 一个修改。
- diff 逐行核对：除标题与分隔线外，行内容、按钮、绑定、计数来源未变。
- 按约定未运行 `swift build` 或 `swift test`，未写实时资料库。视觉需主会话集成后目视确认。

## 风险

- 未归组材料的计数仍取 `unlinked.count`（材料数），而行按 `distinctExpressions` 去重后可能少于该数。这是现状，未改。末行判断用去重后的数组，末尾不会多出一条线。
- `WorkspaceSectionHeading` 的标题不带 `secondaryText`，改为默认主文字色，与「主题材料」一致，但与旧线索区的次级色不同。这是本次对齐的目标。
- 展开内容的行间距从 DisclosureGroup 默认值变为 0，靠分隔线分隔，与「材料」列表一致。折叠时的头部高度多了标题下的 16 与一条发丝线。
- 未目视运行。
