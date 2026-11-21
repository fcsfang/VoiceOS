# 148-A 主题阅读状态跨页保留（WorkspaceTopicReadingView / WorkspaceView）

## 背景
保留一路发现：主题阅读的选中卡片、筛选词、结构展开与键盘卡片环都存在视图本地 @State，页面因 `.id(topic.id + mode)` 重建后全部丢失；从材料/任务返回时选中与视口一并回退。目标：状态按 topic+mode 键存到父级，返回时恢复选中环并滚动到选中卡片。

## 改动
- 新增 `TopicReadingUIState`（selectedSection / showingAllSections / localFilter / keyboardCardID）。
- `WorkspaceTopicReadingView` 增加 `@Binding var uiState`，三个本地 @State 改为基于 uiState 的计算属性（nonmutating set），搜索框改用 `filterBinding`。
- 键盘卡片选中：`onChange(of: keyboardCardFocus.id)` 写回 `uiState.keyboardCardID`；卡片列表 `onAppear` 时按保存 id 重建选中环并 scrollTo 到该卡片。
- `WorkspaceView` 新增 `@State topicReadingStates: [String: TopicReadingUIState]`，调用点传入 Binding（键为 topic.id + mode）。

## 验证
`xcrun --sdk macosx swiftc -parse` 两文件退出码 0；类型级（计算属性、Binding、初始化顺序）留给集成构建。不跑 swift build/test。