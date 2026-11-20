# 134-B 行交互与禁用态一致性

依据只读盘点执行，范围限于指定的六个视图文件，另加 `FeynmanPractice.swift` 与 `QuickNote.swift` 各一处错误文本。未运行 `swift build` / `swift test`（按要求），验证方式为逐文件 diff 静态复核。

## 逐条结果

### WorkspaceDesign.swift `WorkspaceIconButton` (:113-127) — 采纳

组件内新增 `@Environment(\.isEnabled)`。禁用时 `.opacity(0.4)`，hover 背景不显示，`onHover` 也不置位。属组件级修复，所有调用点自动继承。

### WorkspaceActivityViews.swift 子任务/下一步行 (:690-707 / :939-954) — 采纳

- 子任务完成圆圈、子任务删除、下一步完成圆圈均补 `palette.hover` 背景（chipRadius），hover 状态由 `WorkspaceTaskView` 的三个 `@State` 按行记录，同一行内圆圈与删除各自独立。
- 三个控制都只在可操作时响应 hover（子任务看 `current && !planBusy`，下一步看 `!savingAction && state != "dismissed"`），与组件级禁用不显示 hover 的约定一致。
- `.disabled` 时圆圈前景改为 `palette.disabledText`。
- 下一步的「摘除」是 `workspaceQuietCompact`，现有 `WorkspaceButtonStyle` 已自带 hover 背景，未重复处理。

### WorkspaceTopicReadingView.swift 主题 tile (:572-602) — 采纳

- hover 由 accent 描边改为 `palette.hover` 背景，描边只保留 `palette.border` 的常规轮廓。
- 为实现背景 hover，tile 由 `WorkspaceCard` 包一层改为同款内联容器（padding 20、sectionRadius、surface、border），静止态外观与 `WorkspaceCard` 默认参数一致；未改动 `WorkspaceCard` 本身。
- 右上角 `arrow.up.right` 换成既有 `WorkspaceRowChevron()`。
- 同页相邻主题线索行（:105）的「查看」尾注改为 `trailingStyle: .link`，与 tile 一起成为带 chevron 的整行打开行。

### WorkspaceTopicReadingView.swift 值得继续的问题 (:373-387) — 采纳

问题卡补 `@FocusState focusedQuestion`、`.focusable()`、`.focused(_:equals:)`、`.focusEffectDisabled()`，焦点时描边取 `palette.focusRing`，与同页结构网格的焦点模式一致。按统一约定，hover 背景同时由 `palette.selection` 改为 `palette.hover`。

### ReflectionQuestionsView.swift (:131, :228) — 采纳

- 条目菜单的 `ellipsis` 去掉 22pt 固定宽，改为 `minWidth/minHeight = rowActionMinHeight`（24）加 `contentShape`。
- 问题列表行 `.disabled(busy)` 时标题与「更新于」文字改用 `palette.disabledText`；未采用整行 opacity，保持页内文字变色的既定做法。

### ThoughtPanoramaView.swift 工具栏 (:386-454) — 采纳（24pt 方案）

理由：`outlineToolbarButton` 需要 `.popover`，不能换成只接受 action 的 `WorkspaceIconButton`；改成 28pt 会改变工具栏节奏。故统一把 22×22 图标槽补到 `rowActionMinHeight`（24）并加 `contentShape`，间距 8 保持不变。同一工具栏、同类 22pt 的折叠 `toolsMenu` ellipsis（:221）与生成中的 ProgressView 槽位一并补到 24，避免同一行出现 22/24 混排。

### FeynmanPractice.swift (:36) — 采纳

裸 danger 文本改为 `WorkspaceNoticeText(message: severity: .danger)`。

### QuickNote.swift (:77) — 采纳（含一处必要配套）

错误文本改为 `WorkspaceNoticeText`。该面板是独立 hosting root，`WorkspaceNoticeText` 读取 `@Environment(\.workspacePalette)`，而此前未注入，会落回默认石墨 palette；故在同一视图链上补 `.environment(\.workspacePalette, palette)`，让提示跟随用户所选主题。

### WorkspaceReadingViews.swift 可折叠分区标题 (:129-132) — 采纳

可折叠分支的标题 Button 复用既有 `.workspaceHoverHighlight()`，非折叠标题不加 hover。

## 未采纳/未做

- ReflectionQuestionsView 问题列表行本身无 hover 背景：盘点未列为改动项，且该行已有选中背景语义，未额外叠加。
- 「值得继续的问题」卡右上角的 `arrow.up.right` 未换 chevron：它触发的是带当前主题继续讨论，不是导航到某个条目，盘点只要求补焦点环。
- 未运行构建与测试（任务约束）；静态复核覆盖了全部 8 个文件的 diff。
- `deslop` 技能未安装（当前环境只有 pstack 插件），故跳过提交前的 deslop 步骤。