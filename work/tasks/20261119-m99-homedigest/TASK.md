# 波 99 任务 B：首页读者区待办位置与待办计数口径

分支 `work/m99-homedigest`（基于 main 6a46759，已 merge main，无新提交）。

## 目标
首页读者区在观点列表之前露出待办数量；首页快照的待办收集排除需核对（requiresReview）行动，与材料列表 `openActionCount` 口径一致。

## 改动 file:line
- `Sources/VoiceOSCore/RecentContent.swift:425-427`：`RecentContentHomeSnapshot.build` 新增 `reviewRequiredActionIDs: Set<String> = []` 参数。
- `Sources/VoiceOSCore/RecentContent.swift:441-444`：收集 open/current/task 行动时排除该集合中的行动，digest 待办与行尾计数同源变化。
- `Sources/VoiceOSApp/VoiceOSApp.swift:1488-1495`：`publishHomeSnapshot` 用 `sourcePageIndex.requiresReview` 生成排除集并传入。
- `Sources/VoiceOSApp/VoiceOSApp.swift:1504-1512`：把 `publishHomeSnapshot()` 移到 `actionReviewLedgers` 赋值与 `sourcePageIndex` 重建之后（原先在索引重建前调用，会读到上一轮索引）。
- `Sources/VoiceOSApp/RecentContentHome.swift:39`：新增滚动锚点 `home.tasks.summary`。
- `Sources/VoiceOSApp/RecentContentHome.swift:292-313`：把 `ScrollViewProxy` 传入 `readerContent` / `materialReader`。
- `Sources/VoiceOSApp/RecentContentHome.swift:393-439`：标题与摘要之后、观点线程之前新增一行「N 条待办」徽标按钮（`home.tasks.badge`），点击滚动到页尾完整待办列表。
- `Sources/VoiceOSApp/RecentContentHome.swift:555-558`：页尾待办列表加 `.id(tasksAnchor)`；`home.tasks.list` 标识与每条「详情」按钮不变。
- `Tests/VoiceOSCoreTests/RecentContentHomeSnapshotChecks.swift:259-281`：新增 2 项测试。

## 取舍
- 完整待办列表只保留页尾一处（含每条「详情」按钮），顶部只放一行紧凑徽标；不在观点前重复长内容。
- 顶部徽标的点击只滚动到页尾列表，不改原有「详情」交互；键盘与既有标识保持，新增 `home.tasks.badge`。
- 排除集在 App 层以 `SourcePageIndex.requiresReview` 为准；Core 不自行构造 `WorkspaceActionPause.Gate`，因为缺 ledger 时 Gate 默认「需核对」，会把全部行动误排除。
- 偏差：任务卡文件所有权未列 `VoiceOSApp.swift`，但排除集只能在持有 ledger 的调用点计算，因此做了上述两处最小接线；其余文件未动。

## 测试与真实退出码
- `swift build -j 2; echo build_exit=$?` → `build_exit=0`（在 `/tmp/voiceos-swift-build.lock` 下执行）。
- `swift test -j 2; echo test_exit=$?` → `test_exit=0`，`Executed 650 tests, with 0 failures`（基线 648，新增 2）。
- 新增测试：`testReviewRequiredActionsStayOutOfDigestTasks`、`testDigestTasksEmptyWhenEveryActionNeedsReview`，均通过。

## 遗留风险
- `publishHomeSnapshot` 依赖 `sourcePageIndex` 处于当前快照；当前唯一调用点已移到索引重建之后，若未来在别处调用需同样保证顺序。
- 材料页「待办」段仍包含需核对行动；按要求本次只对齐首页快照与材料列表两处，材料页不在改动范围。
- 未在应用内实测滚动行为（未重启应用）；锚点依赖 SwiftUI `ScrollViewReader`，已通过编译与单元测试验证，未做真机 UI 验证。