# 波 86 任务书（2026-11-19）：首页派生与反馈体验

## 背景（发现者 A/B 报告 2026-11-19）

- A6/A14：首页每 body flatMap items、线性找 selected、重算 recentThoughts 分组、每反馈行 outcomeBadge 过滤；`RecentContent` 快照构建对每个材料项 actions.filter 全量行动（O(材料×行动)）。`RecentContentHome.swift:36-43,101-144,233-243,505-512`、`RecentContent.swift:248-271,404-441`。
- B2：首页「整理这份材料」在另一份材料理解中或批量运行时点击毫无反应（reidentify 静默 return；按钮禁用条件未覆盖）。`VoiceOSApp.swift:2594-2603`、`RecentContentHome.swift:557-563`。
- B4：资料库读取失败呈现为「空资料库」（首页空态不读错误）。`VoiceOSApp.swift:1546-1556,1591`、`RecentContentHome.swift:93-99`。
- B7：「在读」状态首页只在 appear 加载一次，材料页修改后首页不刷新。`RecentContentHome.swift:26,62`、`WorkspaceView.swift:269,388-389,1895-1899,2466-2474`。
- B1（首页侧）：组织提示、阅读失败只写全局 status 或页面底部。`RecentContentHome.swift:557-563`。
- B9（首页侧）：首页空态只有「记录想法」，没有导入入口。`RecentContentHome.swift:93-99`。

## 完成判据

1. 首页派生预计算：recentThoughts 分组、每行状态与计数进 `RecentContentHomeSnapshot`（随快照一次）；行只读值。`RecentContent` 的 digest 循环先用 claimID→actions 索引。
2. 「整理这份材料」：理解中/批量运行时显示禁用原因文案，或排队；失败写入行内 toast。
3. 资料库读取失败：首页空态在错误时显示错误态与重试入口（可读 `model.status` 或新增发布错误字段——不得改 VoiceOSApp.swift，只能读现有发布值；若现有值不够，在任务书结果里报告需要的最小跨文件改动）。
4. 阅读状态：改为从 model 的发布映射读取（若 `ControlCenter` 无此映射，采用「首页每次出现与刷新后重读」方案，同样不碰 VoiceOSApp.swift）。
5. 首页空态补「导入录音」入口（复用既有跳转）。
6. 行为、文案、标识、键盘零变化（除上述文案补充）；不加迁移；测试 ≤3（中文断言）；build/test 真实退出码 0（基线 621）。
7. 结果给 file:line 与对照。

## 文件所有权

`Sources/VoiceOSApp/RecentContentHome.swift`、`Sources/VoiceOSCore/RecentContent.swift`、`Sources/VoiceOSApp/MaterialManagementView.swift`、对应测试。不碰其他文件（尤其 VoiceOSApp.swift、WorkspaceView.swift）。

## 约束

16GB：锁 `/tmp/voiceos-swift-build.lock`；先 merge main；不写实时库；不重启应用；不 push、不合并。分支 `work/m86-uxfeedback`。

## 结果

- 分支：work/m86-uxfeedback（基于 main 88fd720；`git merge main --no-edit` 退出码 0，已是最新）。
- 代码提交：9d8a39f「perf(首页): 派生状态与最近想法入快照，整理与空态补反馈」（3 文件，210 增 37 删）。
- 归因（任务书背景 A6/A14、B2、B4、B7、B1 首页侧、B9，对应本任务书第 5-10 行；行号为改动后）：
  - A6/A14（首页每 body 分组、逐行状态、O(材料×行动) digest）：`Sources/VoiceOSCore/RecentContent.swift:393-407` 新增 `RecentHomeRow`（行图标、计数、状态槽枚举）；`410-427` 快照新增 `rows` 与 `recentThoughts`，构造保留默认参数；`438-451` digest 改为 claimID→行动位置索引一次构建，任务仍按行动数组原顺序；`471-490` 行信息与最近想法分组随快照一次算好。视图侧 `RecentContentHome.swift:240-242,249-265,269-271,525-527` 行图标/状态/计数/最近想法改读快照；`118,128,230` 反馈待填徽标每 body 只取一次。
  - B2（整理静默无反应）：`RecentContentHome.swift:571-602` 新增禁用原因（处理录音中、另一份材料理解中、批量重新识别中）；`612-620` 原因判定与 `reidentify` 守卫一致；`622-630` 点击后若未真正开始，立即写入该行行内提示；`632-641` 整理结束（understandingSource 归零）把结果写入该行行内提示。
  - B4（读取失败误呈现为空）：`RecentContentHome.swift:99-115` 空态优先显示 `workspaceLastError` 错误与「重试」（`retryWorkspaceError()`）。现有发布值不足，最小跨文件改动见「遗留风险」第 1 条。
  - B7（在读不刷新）：`RecentContentHome.swift:62-65,67` 改为每次出现与快照更新后重读 `readingStates()`；`ControlCenter` 无发布映射，采用判据 4 的兜底方案。
  - B1 首页侧（失败只写全局 status）：整理失败/未开始改为行内提示（`RecentContentHome.swift:596-598`），不再依赖全局状态。
  - B9（空态缺导入）：`RecentContentHome.swift:112` 空态补「导入录音」，复用 `model.chooseFullRecording()`，由既有 `WorkspaceView.swift:419-421` 跳转到导入录音工具页。
- 测试：`Tests/VoiceOSCoreTests/RecentContentHomeSnapshotChecks.swift:5-16` 辅助构造新增 localOnly/jobState；`:195` 快照内最近想法分组与直算一致；`:215` 行图标/状态/计数（仅本地优先于整理中、反馈行计数）；`:240` digest 任务保持行动原顺序且过滤非任务/已完成。
- 验证：merge_exit=0；build_exit=0（`swift build -j 2`，114.16 秒）；test_exit=0（`swift test -j 2`），624 项 0 失败（基线 621 加新增 3），36.680 秒。构建与测试共用 `/tmp/voiceos-swift-build.lock`（mkdir 抢锁、陈旧锁按 mtime 2400 秒回收、结束 rmdir）；`git diff --check` 退出码 0；未写实时库、未重启应用、未 push、未合并。
- 判据落点：
  - 判据 1：recentThoughts 分组、行状态与计数进快照；digest 用 claimID→位置索引，顺序与旧 filter 一致并由测试锁定。反馈行「结果待填」徽标的输入 `visibleOutcomeFollowups` 不在快照构建入参内（接入需改 VoiceOSApp.swift 调用点），本波改为视图每 body 取一次。
  - 判据 2：理解中/批量运行显示禁用原因；未开始与失败写入行内提示（新增文案见改动）。
  - 判据 3：空态错误态与重试入口已接 `workspaceLastError`；该字段当前不被资料库重载失败写入，最小跨文件改动见下。
  - 判据 4：采用「每次出现与刷新后重读」，未改 VoiceOSApp.swift。
  - 判据 5：空态「导入录音」复用既有跳转。
  - 判据 6：除新增文案外行为、标识、键盘未变；无迁移；测试 3 项，断言为中文；真实退出码见验证。
  - 判据 7：归因 file:line 与对照见上。
- 遗留风险：
  - 资料库重载失败仍只写 `status`（`VoiceOSApp.swift:1555,1591,1609,1618,1626`），`workspaceLastError` 仅由本地转写/文本模型/导出路径写入（`VoiceOSApp.swift:513,1706,2964`）。最小跨文件改动：`WorkspaceErrorRetry`（`VoiceOSApp.swift:13`）新增 `.reload`；上述重载失败 catch 调 `reportWorkspaceError(error.localizedDescription, retry: .reload)`；成功发布时 `clearWorkspaceError()`；`retryWorkspaceError()`（`VoiceOSApp.swift:2973-2981`）加 `.reload: Task { await refresh(.full) }`。首页 UI 已就绪，落地时无需再改本波文件。
  - 反馈行「N 项结果待填」计数若要进快照，需在 `publishHomeSnapshot`（`VoiceOSApp.swift:1476`）把 `visibleOutcomeFollowups.count` 作为 `build` 参数传入；本波未动该文件。
  - `recentThoughts` 的 14 天窗口改为快照发布时求值，不再是渲染时求值；刷新即更新，跨午夜停留在首页时窗口边界可能晚一个快照。
  - 「整理未开始」行内提示依赖 `reidentify` 同步设置 `understandingSource`（`VoiceOSApp.swift:2596` 读码确认，未实机验证）。
  - `MaterialManagementView.swift` 本波无需改动。
