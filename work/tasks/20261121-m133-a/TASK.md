# 133-A 空态统一到 WorkspaceEmptyState 并补齐出路

## 背景

反思、讨论、英文练习、录音跟进等十处界面各自写空态：三处直接使用 `ContentUnavailableView`，一处手写同样的空态分支，两处空态没有出路。同一类界面因此读起来不像一个产品。基准组件是 `WorkspaceEmptyState(title:systemImage:description:actions:)`（WorkspaceDesign.swift:90），本轮把分配到的十处收口到该组件。

## 改法（逐条）

1. ReflectionQuestionsView.swift 采纳。详情窗格空态从裸 `ContentUnavailableView` 改为 `WorkspaceEmptyState`，actions 放「建立主题或问题」，复用文件内 `beginCreating()`，样式取同标签按钮的 `.workspacePrimary`。标题、图标、说明文案原样保留。
2. DiscussionView.swift 采纳。空态从 `ContentUnavailableView` 改为 `WorkspaceEmptyState`，文案不变。原空态没有按钮，未新增 action；Sheet 顶部常驻的「关闭」（dismiss）就是出路。
3. DiscussionHistoryView.swift 采纳。空态已是 `WorkspaceEmptyState`，补「关闭」action，复用 `close` 与 `.workspaceSecondary`。原第 51 行裸 danger `Text` 改为 `WorkspaceNoticeText(message:error,severity:.danger)`，保留 12 点外边距；`palette` 仍用于侧栏底色。
4. EnglishPracticeView.swift 采纳。手写 `ContentUnavailableView` 改为 `WorkspaceEmptyState`，保留「去记录英文表达」action 与 `.workspacePrimary`。`englishStatus` 的错误分支改用 `WorkspaceNoticeText(.danger)`，其余状态仍是原来的次级色 `Text`。`ControlCenter` 把状态与失败写进同一个字符串，视图用 `englishStatusIsError` 按已知状态前缀判别，见风险。
5. RecordingFollowupView.swift 采纳。列表内空态从 `ContentUnavailableView` 改为 `WorkspaceEmptyState`，仍在 `ScrollView` 的 `LazyVStack` 内，滚动行为不变。未加 action，生成入口在视图顶部工具栏。
6. OutcomeFollowupView.swift 采纳。空态补「去行动页」action：先设 `ControlCenter.primary?.pendingWorkspaceRoute = .actions`，再调 `onDone()` 关闭 Sheet。`WorkspaceView.consumePendingNavigation()` 消费该请求并 `go(.actions)`（WorkspaceView.swift:2901）。样式 `.workspaceSecondary`，与「关闭」类出路一致。
7. FeynmanPractice.swift 未采纳（自查后无空态）。没有原话时显示的是复述输入表单本身，输入与结果两种状态都带操作。原第 36 行有裸 danger 错误文本，但不在本轮盘点分配的 error-text 项内，留给 error-text-style 单元，避免越界改并行清单。
8. IncrementalReadingView.swift 未采纳（自查后无空态）。未开始按天读是带按钮的起始面板，转写缺失是流程内提示，都不是「没有内容」的空态；错误已用 `WorkspaceNoticeText(.danger)`。
9. QuickNote.swift 未采纳（自查后无空态）。速记面板始终是输入表单，没有空态；原第 77 行错误是裸 danger `Text`，同样不在本轮盘点分配内。
10. BilingualView.swift 未采纳（自查后无空态）。未配置模型、仅本机、待校正转写、未生成四种状态都是带按钮的设置面板，不是空态；错误已用 `WorkspaceNoticeText(.danger)`。

## 验证

- `xcrun swiftc -parse` 逐个解析六个改动文件，退出码均为 0。
- `git diff --check` 退出码 0；`git diff --stat` 显示六个文件，34 增 15 删。
- 十个文件内已无 `ContentUnavailableView`；Tests 与 docs 不含本轮改动的空态文案，无需同步。
- 按约定未运行 `swift build` / `swift test`，未写实时资料库。视觉需主会话集成构建后目视确认。

## 风险

- `WorkspaceEmptyState` 基于 `ContentUnavailableView`，窄容器与 Sheet 内的表现跟随系统。本轮落点宽度为：反思详情窗格（1020 窗口减 240 列表）、讨论 720、历史 560、英文练习 820 或嵌入式、录音跟进 820 或嵌入式、结果跟进 680 至 820 的可缩放 Sheet。没有比 560 更窄的落点，预计不会截断，但 560 的历史面板与嵌入式英文练习需要目视确认标签和说明不被压缩。
- 录音跟进的空态在 `ScrollView` 的 `LazyVStack` 内，按内容高度显示，不再占据原 `ContentUnavailableView` 的默认高度行为。`OutcomeFollowupView` 已有同样先例。
- `WorkspaceNoticeText` 自带 10 点内边距与圆角底色，替换历史讨论的裸文本后错误区会变高、着色更明显。这是 error-text-style 的目标，但与旧布局不同。
- `englishStatusIsError` 依赖 `ControlCenter` 当前写入的七个状态前缀。日后新增状态，或错误文案恰好以这些前缀开头，会分别被误判为错误或状态。根治需要 `ControlCenter` 把状态与错误分开存储，属于 VoiceOSApp.swift，本轮不改。
- OutcomeFollowupView 新增 `ControlCenter.primary` 调用。单例为空时按钮只关闭 Sheet、不导航；正常 app 路径下主窗口已建立该单例。
- FeynmanPractice 与 QuickNote 的裸 danger 错误文本未处理，理由见第 7、9 条。
- 未目视运行。