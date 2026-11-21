# 141 导航小项补全

## 背景

只读复核给出五项键盘导航缺口：行动/材料页筛选不能左右切换、首页「最近想法」不在时间线键盘序内、首页反馈行 Enter 逃逸、消息监测页无菜单入口、搜索页 query 为空时 Esc 不返回。目标是按现有列表键盘模式补齐，不改业务数据与文案。

## 逐条结果

### 1. 行动页与材料页 ←→ 切换筛选

- `WorkspaceView.swift:2672` 新增共享 `cycledFilter(_:over:forward:)`，按 `SavedViewPage.filters` 循环。
- `handleActionListKey`（现 2676）：repeat 守卫放行 `.leftArrow/.rightArrow`；新增左/右分支循环 `SavedViewPage.actions.filters` 并写回 `actionFilter`。现有 `onChange(of:actionFilter)` 清高亮并在离开「全部/我的待办」时退出多选，焦点留在列表。
- `handleMaterialListKey`（现 2733）：同样放行左右键，循环 `SavedViewPage.materials.filters` 并写回 `materialFilter`；现有 `onChange(of:materialFilter)` 清 `materialKeyboardFocus.id`。
- ⌘1-5 页面切换未动。

### 2. 首页「最近想法」并入时间线键盘序

- `RecentContentHome.swift:243`：`handleTimelineKey` 在 ids 前加合成行 `home.recentThoughts`，仅当 `recentThoughts` 非空。
- 新增 `@State private var recentThoughtsHighlighted`；↑↓ 到第 0 项时只置该标记，不改 `selectedID`，阅读器保持原条目。
- 折叠标题行（`recentThoughtsEntry`，现 710-712）复用 `palette.selection` 背景与 `workspaceFocusRing`，与行卡片选中视觉一致。
- Enter/空格在合成行切换 `recentThoughtsExpanded`；切换逻辑抽为 `toggleRecentThoughts()`，按钮与键盘共用。
- 展开后的想法条目未并入键盘序（按任务约束）。
- 为让选中可见，补 `.id(recentThoughtsRowID)` 与 `onChange(of:recentThoughtsHighlighted)` 滚动到顶；点击任一时间线条目会清空合成行高亮，避免双重选中。

### 3. 首页反馈行 Enter 显式消费

- `RecentContentHome.swift:266-276`：`kind != .material` 时返回 `.handled` 空操作；material 且有 source 仍打开材料。空格只在合成行消费，其余保持 `.ignored`。

### 4. 消息监测菜单项 + ⌘6

- `VoiceOSApp.swift:20`：`WorkspacePageRequest` 增加 `monitor`。
- `WorkspaceView.swift:765`：pending request 映射为 `path=[];page = .monitor;error=""`，与侧栏 `nav` 和设置页的 monitor 入口落到同一 `WorkspacePage.monitor`。
- `VoiceOSApp.swift:4613`：「显示」菜单在「启动」与「返回」之间加入「消息监测」，快捷键 ⌘6；⌘1-5 未改。

### 5. 搜索页 Esc

- `WorkspaceView.swift:467-470`：`page == .search` 时 query 非空先清空；query 已空则无条件 `back()`，不再依赖 `path` 非空（`back()` 在无历史时回首页）。

## 验证

- `swiftc -parse` 三个改动文件通过；按任务约束未运行 swift build / swift test，未写实时库。
- 静态复核：左右键分支位于 return 之前；repeat 守卫放行左右键；筛选写回触发既有 onChange 清高亮。
- deslop 提交前门禁跳过：本机 `~/.claude/plugins/cache` 只有 pstack，未安装 cursor-team-kit。

## 风险

- ⌘6 走 `WorkspacePageRequest.monitor`，依赖侧栏挂载中的 `.onChange` 消费，与 ⌘1-5 同一机制，无新增状态。若未来出现并行主窗口，仍沿用 `ControlCenter.primary`。
- 「最近想法」合成行不改 `selectedID`，阅读器停留在上一次材料；高亮与阅读器选中不同步是刻意取舍，避免选中描述块时清空阅读器。
- 标题行原有 10pt 水平缩进，选中背景绘制在该范围内，比卡片行略窄；视觉复核以真机为准。