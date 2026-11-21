# 139-B2 主题页与主题详情的键盘导航

## 背景
主题页与主题详情此前只能鼠标操作；材料页与行动页已有容器级焦点、↑↓ 步进、↵ 打开与居中滚动的键盘路径。本任务把这套路径补到主题瓦片、线索、尚未归入主题的材料、主题详情「材料」与「回顾」页签，以及阅读卡片和「值得继续的问题」。只新增键盘路径，不改数据逻辑与文案。

## 改法
只改 `Sources/VoiceOSApp/WorkspaceView.swift`（主题页区域及其状态、处理器）与 `Sources/VoiceOSApp/WorkspaceTopicReadingView.swift`。

- **主题瓦片**：容器级 ↑↓ 在可见主题间移动，↵ `selectTopic`。`WorkspaceTopicTile` 新增 `highlighted` 参数，选中背景 `palette.selection`、描边 `palette.focusRing`；hover 逻辑保持。
- **线索列表 / 尚未归入主题的材料**：各自容器 `.focusable()`，↑↓ 步进，↵ 分别打开主题与材料。行高亮用 `palette.selection` 背景加 `workspaceFocusRing`（新增文件内 `workspaceSelectionHighlight`，未选中时透明，不改变原视觉）。同一屏三个列表各自持有焦点状态，只有获得焦点的容器响应键盘。
- **主题详情「材料」页签与「回顾」页签**：每个页签的 sourceRow 列表各自容器级 ↑↓/↵，↵ 打开材料；行高亮同上。
- **主题详情阅读卡片**（`readingCards`）：网格容器级 ↑↓ 在 `displayedSections` 间移动，↵ 复用「内容结构」的 ↵ 语义，切换 `selectedSection` 过滤或取消过滤该小主题；键盘选中卡片加焦点环。
- **值得继续的问题**：保留每个问题按钮原有的 Tab 焦点，新增容器级 ↑↓ 选择与 ↵ 讨论；Tab 焦点与键盘选中都显示焦点环。
- **步进与滚动**：`WorkspaceView` 复用现有 `WorkspaceKeySelection.step`；`WorkspaceTopicReadingView` 不能访问文件私有类型，复制一份 `TopicReadingKeySelection` 并注明可提升共享。选择变化时 `scrollTo(id, anchor: .center)`，与材料/行动页一致。
- **共用推导**：把当前主题阅读数据、可见主题列表、未归组材料、回顾区间与回顾材料提为私有计算属性/方法，视图与键盘处理器共用，避免两处过滤逻辑漂移。

## 等价性
- 文案、数据读写、行结构、hover、滚动位置保存、朗读/无障碍标签均未改；未选中时行与卡片保持原背景。
- 主题列表排序与过滤从视图内联表达式移到 `visibleTopicListings`，表达式逐字相同；未归组材料的拆分仍由 `distinctExpressions` 完成，外层仍以 `!unlinked.isEmpty` 判定，保持原边界。
- 阅读卡片 ↵ 会触发「内容结构」原有的 `onChange(of: selectedSection)` 抢焦点，因此在新的键盘路径内延迟 100ms 把焦点还给卡片容器；鼠标点击结构按钮的行为不变。

## 验证
- `xcrun swiftc -parse Sources/VoiceOSApp/WorkspaceView.swift` 退出码 0。
- `xcrun swiftc -parse Sources/VoiceOSApp/WorkspaceTopicReadingView.swift` 退出码 0。
- `git diff --check` 退出码 0；`git status` 只有上述两个文件与任务记录。
- 逐段 diff 核对：除新增键盘路径与提取的共用推导外无其他改动。
- 按任务约束未运行 `swift build` / `swift test`，未写实时资料库；键盘行为需集成后实机确认。

## 风险与取舍
- 未编译：`swiftc -parse` 只证明语法，类型检查与 SwiftUI 焦点/按键行为需主会话集成构建后实测。
- 阅读卡片没有独立详情页，↵ 采用与「内容结构」相同的 `selectedSection` 过滤语义作为「打开卡片」的现有等价动作；若产品期望其他展开方式需再对齐。
- 主题瓦片网格沿用材料页的 `onAppear` 100ms 后请求焦点，可能与快速点击搜索框存在毫秒级竞争。
- 线索区与未归组材料区是 `DisclosureGroup`，折叠时其内容不渲染，容器也就没有焦点停靠点；展开后可用。这是现有交互的直接结果。
- 三个列表共用一个页面级 `ScrollViewReader`；各列表的 `.id` 在渲染时来自不同集合，概览与详情互斥，不会同屏冲突。