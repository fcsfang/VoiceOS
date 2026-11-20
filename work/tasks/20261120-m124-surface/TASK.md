# 波 124-B：表面层次与 token 化

基线 `work/m124-surface`，工作树 `.worktrees/m124-surface`。目标：页面、卡片、卡内面板与模态各层都使用调色板 token 且层级一致，模态不再依赖系统近白窗口色；卡中卡不再叠第二层 surface。`WorkspaceTheme.swift` 的 palette 值属于 124-A，本波未改。未改布局与文案。

## 层次模型

| 层 | token | 用途边界 |
| --- | --- | --- |
| canvas | `palette.canvas` | 页面底、主窗口内容窗、工具栏条带、sheet/模态根 |
| sidebar | `palette.sidebar` | 导航侧栏、材料侧轨、讨论侧板 |
| surface | `palette.surface` + `palette.border` hairline | 页面上的卡片与区块（`WorkspaceCard`、`WorkspaceSection`、首页卡片、列表浮层） |
| selection | `palette.selection` + `palette.border` hairline | 卡内/面板内的嵌套面板、编辑器与输入区、选中行、图标底；不再用 surface 叠第二层白 |
| hover / pressed | `palette.hover` / `palette.pressed` | 行与控件的交互反馈 |

规则：模态根一律 `canvas`；`surface` 只出现一层，其内部嵌套面板改用 `selection`。系统 Alert 保持不动。

## 逐处清单

### 核心词汇

- `Sources/VoiceOSApp/WorkspaceDesign.swift:353`：新增 `WorkspaceModalSurface` modifier，模态根补 `palette.canvas`。
- `Sources/VoiceOSApp/WorkspaceDesign.swift:369`：`WorkspaceEditorSurface` 由 `palette.surface` 改为 `palette.selection`，编辑器不再在卡内形成第二层白。
- `Sources/VoiceOSApp/WorkspaceDesign.swift:379`：导出 `workspaceModalSurface()`。

### 页面级容器（审计结论，无需改动）

- 主窗口：`WorkspaceView.swift:430` 已有 `palette.canvas`，`windowCanvasTint` 同步 titlebar。
- 侧栏：`WorkspaceView.swift:709` 为 `palette.sidebar`；材料侧轨 `:2744`、`:2752` 同样。
- 首页时间线与阅读器、材料阅读器、各工具页：透明承主窗口 canvas，无第二层底色；`RecentContentHome.swift:100` 顶栏为 canvas。
- 首页卡片 `RecentContentHome.swift:991`（`HomeCard`）：`palette.surface` + border，选中用 `selection` + focusRing。
- `WorkspaceCard`（`WorkspaceDesign.swift:645`）与 `WorkspaceSection`（`WorkspaceReadingViews.swift:170`）：统一 `surface` + hairline。

### 模态根补 canvas（22 个文件，43 处）

`workspaceModalSurface()` 用在 sheet/模态内容根：

- `WorkspaceView.swift:502`（选择提醒清单）、`:578`（保存视图）、`:2460`（安排今天）、`:2695`（本地完成待同步）、`:2853`（合并主题）。
- `ActionClarifyQueueView.swift:107`、`BilingualView.swift:47`、`ConfirmTaskView.swift:30`、`CorrectionImpactView.swift:78` 与 `:149`、`DiscussionView.swift:185` 与 `:200`、`EnglishPracticeView.swift:23`（英文输入预览）、`FeynmanPractice.swift:40`、`IncrementalReadingView.swift:54`、`Onboarding.swift:73`、`OutcomeFollowupView.swift:54`、`QuestionViews.swift:58` 与 `:109`、`RecentContentHome.swift:958`、`RecordingTitleEditor.swift:37`、`ReminderScheduleViews.swift:85` 与 `:127`、`ReminderSettingsView.swift:109`、`TextCaptureView.swift:249`、`:280`、`:293`、`ThoughtPanoramaView.swift:731`（覆盖情况）与 `:927`、`:1050`、`:1125`（三个 reader inspector）、`TranscriptSegmentationView.swift:40`、`VoiceOSApp.swift:4673`、`:4735`、`:4806`、`:4880`、`WeeklyReviewView.swift:168`、`WorkspaceActivityViews.swift:1522`、`WorkspaceSourceView.swift:1630`、`:1676`、`:1716`。
- `VoiceOSApp.swift:100`：`ImportBatchReportView` 自行解析已存主题，直接补 `palette.canvas`。
- `WorkspaceView.swift:531`：在 WorkspaceView 的全部 sheet 之外注入 `\.workspacePalette`，让这些模态读到当前主题，而不是缺省石墨。

### 卡内嵌套面板改 selection（白上白）

- `WorkspaceDesign.swift:369`：共享编辑器面。
- `TextCaptureView.swift:390`：`WorkspaceFieldSurface`，模板名输入位于 `WorkspaceCard` 内。
- `KnowledgeReviewView.swift:163`：知识核查 issue 卡位于 `WorkspaceCard(padding:14)` 内。
- `WorkspaceMonitorView.swift:618`：监测条目位于报告 `WorkspaceCard` 内。
- `WorkspaceView.swift:3111`：主题认识录入编辑器，与共享编辑器保持同一 tone。
- `VoiceOSApp.swift:4926`、`:4938`、`:5028`：静默回顾与相关性判断的嵌套面板由系统 `.quaternary` 改为 `palette.selection`；`:4893`、`:4998` 补 `palette` 环境。

### selection 使用点与白上白判断

- 选中行：`WorkspaceListRow`（`WorkspaceDesign.swift:322`）、侧栏导航（`WorkspaceView.swift:725`）、保存视图行（`:738`）、搜索键盘高亮（`:1611`）、首页行（`RecentContentHome.swift:999`）。
- 面板：主题创建（`WorkspaceView.swift:1153`）、任务（`WorkspaceActivityViews.swift:556/563/581/658/754`）、周回顾（`WeeklyReviewView.swift:328/510/591/639/668/737/782/827`）、主题阅读（`WorkspaceTopicReadingView.swift:223/236/381`）。
- 编辑器/输入：上述 `selection` 化各点；图标底 `selection.opacity(0.6)` 多处。
- 结论：本波之后，审计范围内没有「surface 卡内再叠 surface」；嵌套一律降到 `selection`。`selection` 与 `surface` 的明度差（浅色约 `E7E7E7` vs `FCFCFD`，鼠尾草 `E6EEE5` vs `FFFFFF`）偏小，层级能否读出来取决于 124-A 的 token 值；本轮未改值。侧栏导航选中色（`selection`）与侧栏底（`sidebar`）在浅色下很接近，同样交给 124-A 拉开。

## 未改与理由

- 阅读器/时间线窗格保持透明承 canvas：再加一层同色底只增加层级噪音。
- `ReflectionTimelineView`（`ReflectionGraphView.swift` 内）atlas 根已有 `palette.canvas`；曾给子列表 `ReflectionEventListView` 加底，确认重复后撤回，未留在 diff 里。
- `DiscussionHistoryView.swift:56` 与 `WorkspaceDiscussionView.swift:157` 保留显式 `palette.sidebar`：它们是侧板语义，而不是内容窗。
- `PanoramaConstellation.swift:1155/1172` 的 `.ultraThinMaterial` 药丸是画布上的浮层，透视是刻意的，未 token 化；popover（全景大纲、引用浮层）走系统材质，未动。
- 系统 Alert、菜单、NSOpenPanel 未动。
- 浮动横条（撤销、选择操作、回听条、错误条）保持 `surface`：它们是悬在 canvas 上的独立层，不是卡内面板。

## 验证

未构建（波次批处理）。已完成：

- `xcrun swiftc -parse` 对 26 个改动文件全部通过，`parse_fail=0`。
- `git diff --check` 干净。
- `git diff --stat`：26 文件，66 插入，8 删除。

## 未做与风险

- 没有运行应用做视觉核对；最终观感依赖 124-A 的 palette 值与本波的层级同时到位。
- 场景级 sheet（`TextCaptureView`）仍从场景环境取 palette，场景根没有注入主题，浅色/深色下会落在缺省石墨；`ImportBatchReportView` 已自行解析主题规避。彻底修复需要场景级 palette 注入，属于主题传播，未在本波做。
- `selection` 与 `surface` 的对比度、侧栏选中与侧栏底的对比度，需要 124-A 在 token 值上给出层级；本波只保证不再叠第二层 surface。
- 未 push、未合并、未开 PR。