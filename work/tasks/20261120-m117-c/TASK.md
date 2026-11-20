# 波 117-C 无障碍：装饰图标、ProgressView 命名与异步完成播报

基线 `work/m117-c`，工作树 `.worktrees/m117-c`。只改 `Sources/VoiceOSApp/` 下八个文件：`WorkspaceDesign.swift`、`WorkspaceView.swift`、`VoiceOSApp.swift`、`WeeklyReviewView.swift`、`WorkspaceProcessingView.swift`、`KnowledgeReviewView.swift`、`WorkspaceActivityViews.swift`、`MaterialManagementView.swift`。

## 目标

异步完成与计数变化基本静默，一批 ProgressView 不再无名，设计系统里的装饰图标不再被 VoiceOver 读名。

## 逐处修法

### 1. 装饰图标隐藏（`WorkspaceDesign.swift`）

- `:56` 搜索框放大镜、`:134` `WorkspaceNoticeText` 严重度图标、`:291` `WorkspaceListRow` 行首图标补 `.accessibilityHidden(true)`。
- `:117` `WorkspaceIconButton` 已有 label，未动。
- 核对结论：`WorkspaceSection` 标题图标不在 `WorkspaceDesign.swift`，实际位于 `Sources/VoiceOSApp/WorkspaceReadingViews.swift:183-186`；该文件不在本单元可改范围，未动。

### 2. ProgressView 命名

- `WorkspaceView.swift:660` 侧栏 spinner：`organizingTopics` 时邻近文字「AI 正在连接主题」已表达，隐藏；仅 `assistantBusy`/`followupBusy` 时无文字，补 `.accessibilityLabel("正在处理")`。
- `WorkspaceView.swift:1064`、`:1866`、`:1926`、`:1953`、`:1966`：邻近文案或按钮忙态文案已完整表达（「AI 正在按内容连接主题…」「正在备份…」「正在重新整理…」「正在重新识别…」「正在重试…」），spinner 保留视觉、从无障碍树隐藏，避免重复朗读。
- `MaterialManagementView.swift:75` 无文字 spinner 补 `.accessibilityLabel("正在处理材料")`。
- `KnowledgeReviewView.swift:31` 标题旁 spinner 补 `.accessibilityLabel("正在核查知识")`；`:61` 排队/进行中 spinner 因邻近文字已表达而隐藏。
- `WeeklyReviewView.swift:121` 已有可见文字「正在读取本周行动…」，未动。

### 3. 异步完成播报

统一 `AccessibilityNotification.Announcement(...).post()`（先例 `WorkspaceDesign.swift:216`），只在终态播一次。

- 检索（`WorkspaceView.swift:1594` 起）：成功后以 `term + 结果总数` 为签名，签名变化才播「检索完成，N 条」；失败播「检索失败」，同一词失败不重复；清空搜索词时重置签名。180ms 防抖与 `.task(id: term)` 取消保证打字过程不会逐键播报。
- 每周回顾（`WeeklyReviewView.swift:148`）：`.onChange(of: loadState)`，新态为 `.loaded` 且上一态不是 `.loaded` 时播「本周行动已载入」。
- 处理完成（`WorkspaceProcessingView.swift:746`）：`.onChange(of: model.recentCompletions.first?.id)`，首条 id 变化且非空时播「已完成：<标题>」；按 id 去重，列表截断到 5 条后仍能识别新完成。
- 知识核查（`KnowledgeReviewView.swift:105`）：`.onChange(of: record?.state)`，从 `queued`/`running` 跃迁到 `completed` 播「知识核查已完成」，到 `failed` 播「知识核查未完成」；计数徽章不逐次播报。
- 反馈历史（`WorkspaceActivityViews.swift:1103`）：`loadFeedback()` 成功时，只有慢载占位曾出现（`feedbackPlaceholderVisible`，即等待超过 150ms）才播「反馈历史已载入」；即时返回不播，避免每次切任务都响。
- `WorkspaceSourceView`、`WorkspaceMonitorView` 不在本单元，未动。

### 4. Esc 关闭

- `VoiceOSApp.swift:95` `ImportBatchReportView`「完成」保留 Return，追加 Escape。
- `VoiceOSApp.swift:4858` `BackupLibraryRestoreView`「取消/完成」追加 Escape。
- `WorkspaceView.swift:2611` 本地待同步关闭按钮追加 Escape。

### 5. 文案与标识

新增只有无障碍播报与无障碍标签，没有可见文案变更；identifier 未改。

## 验证

共享锁循环，工作目录 `.worktrees/m117-c`，`swift build -j 2` 与 `swift test -j 2` 串行，只认真实退出码：

- `build_exit=0`
- `test_exit=0`
- `Executed 669 tests, with 0 failures (0 unexpected) in 46.948 (47.014) seconds`
- 代码提交 `b88c85e feat(a11y): 隐藏装饰图标，命名进度指示并播报异步完成`

## 未做与取舍

- `WorkspaceSection` 标题图标在 `WorkspaceReadingViews.swift:184-186`，不在本单元八个文件内，未改；需要在后续单元处理。
- 核对时发现、但不在任务清单内的无名 spinner 未改，保持与已验构建一致：`WorkspaceActivityViews.swift:82`、`:579` 邻近文字已表达（后者已 `.combine`）；`:661` 重复设置 Picker 忙态无文字；`WorkspaceProcessingView.swift:236` 仅进度条表示忙；`VoiceOSApp.swift:4705` 邻近文字「Qwen 正在本机转写…」已表达。留作后续。
- 未重启应用、未做 VoiceOver 真机听读；验证止于全量构建与测试。
- 播报去重状态在进程内（`@State` / 上次签名），页面重建后会重新播报一次终态。
- 检索播报以「词 + 总数」为签名：同词同数不重复；点「显示全部」扩大结果时会按新总数再播一次。
- 知识核查 `frozen` 终态未播报：它保留历史，不等同于完成或失败。