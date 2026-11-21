# 142-B 工作区状态与键盘可达性（WorkspaceView / WorkspaceMonitorView / MaterialManagementView）

## 背景
只读发现（交互 + 状态两路）确认 7 处：搜索页空词材料列表未合并连续表达、顶层导航清空所有页滚动位置、搜索忙占位无慢加载门控、监测设置页操作失败无就地反馈、最近搜索删除按钮只在 hover 出现、侧栏设置与保存视图行无选中态、材料行键盘菜单缺阅读状态与拆分。目标是全部沿用仓库既有模式，逐个最小修复，不改业务逻辑。

## 文件清单（只允许动这三个文件）
- Sources/VoiceOSApp/WorkspaceView.swift
- Sources/VoiceOSApp/WorkspaceMonitorView.swift
- Sources/VoiceOSApp/MaterialManagementView.swift

## 逐条

### 1. 搜索页空词材料列表与材料页同投影
- 约 1736 行 `let sources=model.records.filter { !$0.isTrashed }` 改为 `let sources=distinctExpressions(model.records.filter { !$0.isTrashed })`（`distinctExpressions` 已存在，约 1010 行，会折叠连续表达并保留独立上下文录音）。
- 约 2863 行 `searchKeyboardRows` 的空词分支同样换成 `distinctExpressions(...)`，保证键盘序与渲染行 id 一致。
- 区块标题计数 `材料与原话 · N` 自动跟随投影后的数量，不改文案。

### 2. 顶层导航不再清空滚动位置
- `go(_:)`（约 3011 行）删除 `if next.isTopLevel { scrollPositions.removeAll() }`；`openSavedView`（约 3190 行）删除其中的 `scrollPositions.removeAll()`。
- scrollKey 已含 page 与筛选（约 989-998 行），不同筛选各有条目，无需清空。

### 3. 搜索占位加 150ms 慢加载门控
- 约 1755 行 `if searchBusy && searchHits.isEmpty { ProgressView("正在检索…") }` 改为本地 `@State showSlowSearch` + `.workspaceSlowLoading(searchBusy && searchHits.isEmpty, into: $showSlowSearch)`（门控挂在搜索容器上，参考 WeeklyReviewView:159 的用法），占位只在 `showSlowSearch` 时渲染。

### 4. 监测设置页就地显示操作结果/失败
- `settingsSection`（约 842 行）末尾追加：`if !model.monitorStatus.isEmpty { Text(model.monitorStatus).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).textSelection(.enabled) }`，与「报告」页 runBar 的展示方式一致（不引入新告警级别判断）。

### 5. 最近搜索删除按钮焦点可见
- `RecentSearchChip`（约 3464-3492 行）：新增 `@FocusState private var removeFocused: Bool`，删除 Button 加 `.focused($removeFocused)`；可见与命中条件改为 `hovered || removeFocused`（参照 RecentContentHome.swift:913 的 `visible = hovered || focused` 模式）。

### 6. 侧栏设置行与保存视图行补选中态
- 设置行（约 754 行）：`page == .settings` 时背景 `palette.selection`、`.accessibilityAddTraits(.isSelected)`，与 787/792 行的导航行模式一致；非选中保持现状。
- 保存视图按钮（约 725-737 行）：当前页与当前筛选匹配时同样加选中背景与 isSelected。

### 7. 材料紧凑菜单补阅读状态与拆分
- `MaterialManagementControls`（MaterialManagementView.swift）新增可选回调：
  `var onSetReadingState: ((SourceReadingState) -> Void)? = nil`、`var onSplitExpression: (() -> Void)? = nil`、`var onRejudgeExpressions: (() -> Void)? = nil`。
- compact 菜单在「归档/回收站」之前加：`Section("阅读状态")` 三项（标为未读/在读/已读，调用 onSetReadingState），count > 1 且有回调时加「拆为独立录音」「重新判断连续表达」（重新判断在 `model.fullRecordingBusy || model.understandingSource != nil` 时 disabled）。
- WorkspaceView 材料页 1102 行调用点传入闭包：`onSetReadingState: { setMaterialReading(source.id, $0) }`、`onSplitExpression: { splitMaterialExpression(model.sourcePageIndex.expression(for: source.id)?.sourceIDs ?? [source.id]) }`、`onRejudgeExpressions: { rejudgeMaterialExpressions(...) }`（右值同上下文菜单 2305 行处）。
- full 样式不动；右键菜单保留。

## 约束
- 不改业务逻辑、文案、数据层；不改其它文件。
- 不跑 swift build/test（波次批处理）。改动文件跑 `xcrun --sdk macosx swiftc -parse <files>`，以真实退出码为准（不经管道）。
- 完成后在本工作树提交，尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`；不推送。

## 验证
- `swiftc -parse` 退出码 0。
- `git diff --stat` 只触及清单内文件。
- 回报：提交哈希、逐条完成情况、任何判定不成立的条目及证据。