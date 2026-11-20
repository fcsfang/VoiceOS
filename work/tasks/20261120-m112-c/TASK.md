# 波 112-C 行动详情的反馈与变更历史加载态

基线 `work/m112-c`，工作树 `.worktrees/m112-c`。只改 `Sources/VoiceOSApp/WorkspaceActivityViews.swift`。

## 修法

1. 反馈历史三态。新增 `feedbackLoading` / `feedbackPlaceholderVisible` / `feedbackGeneration`（`WorkspaceActivityViews.swift:280-282`）。`loadFeedback()` 开始置 `feedbackLoading = true`，`defer` 只在代数仍是最新时清位（`:1088-1108`），被 `.task(id:)` 重启或被重试顶掉的旧读取不会把新读取的加载态提前关掉；旧读取的结果与错误也按代数丢弃（`:1102`、`:1106`）。切换行动时一并清空历史、错误与占位。
2. 150ms 占位门控。新增 `.task(id: feedbackLoading)`：加载超过 150ms 才把占位行置为可见，短于 150ms 的读取不显示占位，避免闪烁（`:838-842`），与 `WeeklyReviewView` 的慢加载门控同一写法。占位行是 spinner +「正在读取反馈历史…」，固定最小高度 180，接近单条记录的历史卡片高度，减少数据落地时的整页跳动（`:759-769`）。数据到达即被真实卡片替换；失败仍走原有错误 +「重试读取反馈历史」（`:755-757`）。
3. 变更历史独立错误与真实重试。`revisionsError` 取代原先写进通用 `error` 的做法（`:284`、`:1110-1114`）。`ActionRevisionHistoryView` 增加 `loadError` 与 `retry`，在「记录与依据」卡片内直接渲染 `WorkspaceNoticeText` 与「重试」（`:1330-1346`），重试调用 `loadRevisions()`（`:813`）。加载入口明确存在，所以给的是真重试，不是假按钮。
4. 通用 `error` 与重试配对。新增 `errorRetry` 与 `fail(_:retry:)`（`:289`、`:1194-1197`），文案按 `InlineFailurePresentation` 的「操作 + 原因」口径。有真实闭包的失败（读取子任务、增删子任务、预计时长、下一步、澄清、重新确认、分析）在通用错误旁给「重试」（`:816-823`）。不可构造安全闭包的失败写明下一步：保存重复（`:424`）、撤销（`:1272`、`:1279`）、交给 AI（`:1304`）。会改状态的操作用页面内 `InlineActionFailure`（自带重试）呈现，不再同时写通用 `error`，同一失败只出现一处（`:1009`、`:1195-1200`、`:1213`、`:1231`、`:1239`、`:1247`、`:1280`）。
5. 未改任何 accessibility identifier，未动视觉系统与卡片样式；新增按钮沿用既有样式与标签命名。

## 证据行号

- 状态：`WorkspaceActivityViews.swift:280-289`。
- 占位行与反馈错误重试：`WorkspaceActivityViews.swift:755-769`。
- 通用 error 与重试：`WorkspaceActivityViews.swift:816-823`。
- 加载门控：`WorkspaceActivityViews.swift:838-842`。
- `loadFeedback`：`WorkspaceActivityViews.swift:1088-1108`；`loadRevisions`：`:1110-1114`。
- `fail` 辅助：`WorkspaceActivityViews.swift:1194-1197`。
- 变更历史错误行：`WorkspaceActivityViews.swift:1330-1346`。

## 验证

共享锁循环，工作目录为工作树。命令一次取得锁并在后台完成。

- `build_exit=0`
- `test_exit=0`
- `Executed 669 tests, with 0 failures (0 unexpected) in 43.777 (43.836) seconds`

## 未做与取舍

- 未做真实 UI 驱动验证：本轮约束是不重启应用，验证止于全量构建与测试。
- 占位行 `minHeight: 180` 按单条反馈记录卡片估算，未在真机量测；多条记录时卡片更高，落地仍可能有少量跳动。
- 变更历史只补了错误与重试，没有加加载占位；任务范围只要求反馈历史。
- 保存重复、撤销、交给 AI 没有构造重试闭包：重复保存需要重新触发绑定，撤销状态已复位、重放会走错分支，交给 AI 的去重语义在 `ControlCenter` 内、无法在本文件保证幂等。三者改为文案写明下一步。
- 旧代读取若在取消后仍返回，结果与错误按代数丢弃；但存储层是否响应取消不在本文件控制内。
- 状态类操作失败现在只在页面内 `InlineActionFailure` 展示（含重试），通用 error 不再重复同一文案。
- 未 push、未合并。