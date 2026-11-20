# 133-B 错误可重试、慢加载门控、失败不整页消失

基准：main 869afae。
范围：RecentContentHome、ReflectionGraphView、WeeklyReviewView（仅作模式参照）、AssistantExecutionView、ReflectionChangeView、WorkspaceDiscussionView、WorkspaceProcessingView、WorkspaceMonitorView、ThoughtPanoramaView，以及 WorkspaceView 的 :455 / :608 / :870 / :876 / :884 / :943 / :1611。

## RecentContentHome.swift

- [采纳] :126 首页空态自定义 VStack → WorkspaceEmptyState（图标 tray）。读取失败、有材料但无可读内容、空库三种分支各用一个空态，actions 复用原有「重试」「记录想法」「导入录音」按钮。读取失败分支不再自绘 sectionTitle 与 danger Label，错误原文进入 description，重试仍以 `workspaceLastErrorRetry != nil` 为条件。

## 错误样式统一

- [采纳] AssistantExecutionView :67 / :228 / :258 的裸 danger Text → `WorkspaceNoticeText(severity: .danger)`。:228 保留 `InlineFailurePresentation.message(operation: "代办")` 原文案。
- [采纳] ReflectionChangeView :54 → WorkspaceNoticeText，保留「继续讨论」operation 文案与 padding(16)。
- [采纳] WorkspaceDiscussionView :68 → WorkspaceNoticeText，保留「这次回复未完成：」前缀与 `reply.error` 的回退文案。
- [采纳] WorkspaceProcessingView :841 → WorkspaceNoticeText。
- [采纳] ReflectionGraphView :150 删除底部重复的裸 danger。错误只保留一处：无 focus 时在空态中，有 focus 时在区块级错误行。

## 缺失重试

- [采纳] ReflectionGraphView :147 回顾失败空态加「重试」。闭包调 `refresh()` 而不是裸 `reload()`：refresh 会先补载失败的主题列表再 reload，与页头刷新按钮同一路径；只调 reload 在主题列表为空的主题模式下会直接返回，重试无效。
- [采纳] WorkspaceView :1611 检索失败在 WorkspaceNoticeText 旁加「重试检索」，闭包调现有 `loadSearchHits(term)`，term 与当前输入同步取值。
- [采纳] WorkspaceView :455 主题回顾失败不再清空 topicFocus，改设全局 error + errorRetry（复用文件内 `fail(_:retry:)` 配对）。重试通过 `topicLoadToken` 进入 `.task(id:)` 的 key 触发重跑，SwiftUI 负责取消旧任务，避免并发重复。
  - 状态残留防护：失败时只在与当前 topic 相同（`topicFocusTopicID == id`）才保留旧 focus；切换主题失败会清空，避免把上一主题的图谱挂在当前主题下。
  - 成功时仅当横幅错误仍是本次主题错误（`error == topicLoadError`）才清除，不误清其他操作的错误。

## 慢加载 150ms 门控

- [采纳] ReflectionGraphView :119 新增 showSlowLoad；`.task(id: loading)` 睡 150ms 后仍在 loading 才显示 ProgressView，否则留白。reload 开始时重置。
- [采纳] WorkspaceMonitorView :231 页面级一条门控：showSlowLoad 同时控制今日报告、历史报告、来源状态三处 spinner；retryMonitorLoad 开始时重置。MonitorLoadState 补 : Equatable 供 `.task(id:)` 使用。
- [采纳] WorkspaceView :608 启动全屏 spinner 加 150ms 门控（showStartupProgress + workspaceStarting），快速启动不再闪。
- [未改] WeeklyReviewView :117-152 已是同一模式（showSlowLoad + 150ms），作为参照保留，无需改动。

## 局部失败保留旧内容

- [采纳] ReflectionGraphView :228 reload 不再无条件清空 focus：sameRequest（requestedKey == loadedKey）时失败恢复 previousFocus，并显示区块级错误行 + 重试；换主题或换周期仍先清空，避免错位展示。
- [采纳] WorkspaceView :455 同上，保留策略见「缺失重试」一节。
- [采纳] ThoughtPanoramaView :650 state 为 nil 且 readError 非空时 emptyMode 返回 .readFailed(error)，空态提供「重试读取」（retryRefresh）与「打开材料」，不再永久 spinner。

## 空态与出路

- [采纳] WorkspaceView :943 `unavailable(_:description:)` 由裸 ContentUnavailableView 改为 WorkspaceEmptyState，统一带「回到行动」（go(.actions)）。:870 / :876 / :884 三处调用不改即获得该动作；材料不可用处保留原文案「可以搜索其他材料，或回到主题」，另加「回到行动」作为退出。
- [采纳] ThoughtPanoramaView :439 / :699 两个空态补「打开材料」，点击先收起当前弹层再调 openMaterials。

## 验证

- `xcrun swiftc -parse` 十个文件（含作参照的 WeeklyReviewView）退出码 0。
- `git diff --check` 退出码 0；工作区只有上述九个文件被修改。
- 按任务约束未运行 swift build / swift test，未写实时资料库。
- 未做运行时验证；重试的取消与去重依赖 SwiftUI `.task(id:)` 的取消语义。

## 风险与未验证项

- retain-old-content 状态残留：ReflectionGraphView 以 loadedKey 判定 sameRequest。首次加载失败时 loadedKey 为空、focus 仍为 nil，行为正确；同一 key 刷新失败后保留旧内容并显示错误行，用户可能误以为内容已更新。
- WorkspaceView 的 topicFocus 只在 topic 相同时保留；topic 自身 updatedAt 变化也属于同一 topic，刷新失败时继续显示上一版并给错误行，这是目标行为，但同样存在「旧内容看似最新」的歧义。
- WorkspaceMonitorView 前 150ms 不渲染今日报告卡片，慢加载时布局会在 150ms 后出现；快速加载时区块直接出现，无 spinner。
- WorkspaceView 材料不可用处的「回到行动」是统一出路，语义上不如「回到主题」贴切；如需要专属退出，可把 helper 参数化为回调。
- 未改 WeeklyReviewView，它是本任务的参照实现，当前已满足门控与重试模式。