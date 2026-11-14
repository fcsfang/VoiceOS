---
status: in_progress
started: 2026-11-14
updated: 2026-11-14
branch: work/quick-wins-2
owner: coordinator
---

# 快速赢面第二批

## 目标

继续实现 `docs/product/reference-products.md` 第 9.1 节。这一批五项，阅读状态、批量选择、悬停预览、逐句高亮、讨论追问建议。另有两项按现状处理。权限渐进已经满足，麦克风在首次口述时才请求，拒绝后状态栏提示仍可导入文件，应用没有本地通知子系统，不新增提示。保存视图在阅读状态与批量选择落地后同分支接续。

## 方法

沿用第一批。写入代理只写代码，不编译，不启动应用。全部集成后只跑一次 `swift build -j 2` 与一次 `swift test -j 2`。三个单元并行，保存视图等第一批工作台单元集成后再派。

基线 `main` 为 `2b67352`（PR #147 已合并），schema 55，152 项测试。`SourceReadingState` 存储已存在，签名见第一批任务卡。

## 单元

### Y1 工作台列表（阅读状态与批量选择）

文件：`Sources/VoiceOSApp/WorkspaceView.swift`、`Sources/VoiceOSApp/WorkspaceListControls.swift`（新，`extension ControlCenter`）。

阅读状态：
- 材料页标签改为「日常材料」「未读」「在读」「已归档」「回收站」。未读与在读只列未归档未删除且状态匹配的材料，状态默认未读。
- 材料行右侧显示状态小字，未读不显示，在读显示「在读」，已读显示「已读」。
- 材料行右键菜单提供「标为未读」「标为在读」「标为已读」。
- 打开材料时，若当前为未读，自动标为在读。放在 `go(_:)` 处理 `.source` 的分支，异步写入，失败只进现有错误提示。
- 状态读写走 `model.readingStates()` 与 `model.setReadingState(sourceID:state:)`，新方法在 `WorkspaceListControls.swift`，通过内部 `store` 访问 `sourceReadingStates` 与 `setSourceReadingState`。

批量选择：
- 行动页头部加「选择」按钮，只在「全部」「我的待办」显示。进入选择模式后行动行改为勾选行为，点击切换选中，不导航。
- 底部浮条显示「已选 N 条」，按钮「标为完成」「不再跟进」「取消」。执行前用确认弹窗写明影响条数，执行后逐条走现有 `model.changeAction(record, state:)`，失败收集为一条错误提示，刷新后清空选择并退出选择模式。
- 只允许选中当前 `open` 且 `validity == "current"` 的行动。不改提醒事项的批量安排，改天不提供批量入口。

### Y2 阅读细节（悬停预览与逐句高亮）

文件：`Sources/VoiceOSApp/WorkspaceSourceView.swift`、`Sources/VoiceOSApp/WorkspaceActivityViews.swift`、`Sources/VoiceOSApp/QuoteHoverPreview.swift`（新）。

悬停预览：
- 新组件 `QuoteHoverPreview`，悬停 0.4 秒后在锚点下方弹出小面板，显示来源标题、原话片段与「打开材料」。移出即关闭，不抢焦点。
- 用在任务页 `ActionOriginalQuotes` 的每条原话与来源行，以及材料页原话依据列表里的「打开材料」类入口。已有直接展示的原话不必再加。

逐句高亮：
- 材料页「原话、来源与回听」的 span 列表在播放时只高亮当前句，其余保持常态。用 `model.player` 的当前时间与 span 的 `startMS`、`endMS` 计算，0.3 秒刷新一次，暂停或播放器为空时不高亮。
- 高亮只改背景与文字权重，不移动阅读位置，不自动滚动。
- 不给 `VoiceOSApp.swift` 加发布字段，计时器留在视图内。

### Y3 讨论追问

文件：`Sources/VoiceOSApp/DiscussionView.swift`、`Sources/VoiceOSCore/FollowupSuggestions.swift`（新）、`Tests/VoiceOSCoreTests/FollowupSuggestionChecks.swift`（新）。

- 纯函数 `FollowupSuggestions.suggest(claims:sources:)` 返回 2 到 3 条建议，每条含标题、可编辑提示词、出处（claimID 与来源标题）。规则按确定性模板，例如针对条件、反例、下一步各一条，优先取有原话与来源的 claim，陈述相近的只留一条，总数上限三条。没有可用 claim 时返回空，界面不出现该区。
- 讨论页输入框上方加「可以接着问」一排按钮，点击把提示词插入草稿，不自动发送，按钮下方用小字标出处。替换现有的固定 followup 列表，保留用户手动编辑。
- 测试覆盖无输入、单条、多样、去重、上限三条、出处标题。

### Y4 保存视图（Y1 集成后接续）

文件：`Sources/VoiceOSApp/WorkspaceView.swift`、`Sources/VoiceOSApp/SavedViews.swift`（新）。

- 侧栏在「启动」之后加「视图」分区，列出已保存视图，最多 8 条。每条保存名称、目标页与过滤条件，材料页与行动页各支持。
- 材料页与行动页头部加「保存当前视图」，弹窗输入名称。右键已保存视图可删除。持久化用 `UserDefaults`，按资料库根路径分键，避免不同资料库串视图。
- 点击视图跳到对应页并应用过滤。视图只保存过滤条件，不保存滚动位置与搜索词。

## 集成顺序

Y1、Y2、Y3 并行。Y1 先合入根分支，随后 Y2、Y3，再派 Y4，最后统一编译。

## 验证

- 单次 `swift build -j 2`，修完错误后单次 `swift test -j 2`。
- 实机用隔离副本核对：材料页未读与在读过滤、行状态与打开后自动在读；行动页选择两条批量完成与撤销入口不冲突；任务页原话悬停预览；播放一段录音时 span 列表逐句高亮；讨论页出现有出处的追问并插入草稿。
- 无法实机核对的项目写明原因。

## 已知边界

- 批量改天不提供，逐条改天依赖提醒事项链接与外部写入。
- 逐句高亮只在材料页的原话片段列表，不改全文逐字稿编辑器。
- 追问建议是确定性模板，不调用模型。

## 链接

- `docs/product/reference-products.md` 第 9.1 节
- 第一批任务卡 `work/tasks/20261114-quick-wins-wave-1/TASK.md`
