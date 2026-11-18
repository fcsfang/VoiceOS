# 波 80 任务书（2026-11-18）：处理页与行动页剩余全库直算

## 背景（波 79 遗留清单，2026-11-18）

波 77/79 已把来源页、材料页与首页主路径改为 `SourcePageIndex` 索引读。波 79 结果列出的未覆盖扫描点：

1. `WorkspaceProcessingView.swift:117,143` 的 `workspaceTaskRequiresReview` / `workspacePausedTasks` 仍整库直算；`WorkspaceView.swift:1181` 行动页每次 body 调 `workspacePausedTasks`，规模 O(行动数 × 材料数)。
2. `WorkspaceView.swift:1854` `recordingExpressionIssue(in:)` 对多段表达每次 body 重算 digest。
3. `WorkspaceView.swift:1908` 逐行查 reminderLinks；`latestAnalysisState` 每行过滤 assistantExecutions。
4. `MaterialManagementView` 与 `RecentContentIndex` 仍各自建目录。
5. 任务页/讨论入口按 dismissed 行动查询；索引只含未 dismiss 行动——若要索引化，在 `SourcePageIndex` 保存全量 `allActionsByID`。

## 完成判据

1. 上述 1-3 与 5 的索引化（4 视剩余时间，列为可选）：每处有归因引用（波 79 结果或本波 sample/计时），测试内计时对照（旧直算 vs 索引读）。
2. `workspacePausedTasks` 若进入索引：dismiss 语义必须保持（任务页需要全量，行动页需要未 dismiss），两种访问器命名明确区分。
3. 行为、文案、标识、键盘、选中、滚动锚点零变化；不加迁移。
4. `swift build -j 2` / `swift test -j 2` 真实退出码 0（先 merge main，基线 619 项）；新增纯逻辑测试 ≤3。
5. 结果给出改动清单（file:line）、对照数据、仍留的扫描点（供下一波）。

## 文件所有权

- `Sources/VoiceOSApp/WorkspaceView.swift`
- `Sources/VoiceOSApp/WorkspaceProcessingView.swift`
- `Sources/VoiceOSApp/MaterialManagementView.swift`（仅可选第 4 项）
- `Sources/VoiceOSCore/RecordingContext.swift`（索引扩展）
- 对应测试
- 不碰 `WorkspaceSourceView.swift`、消息监测、QQ、提醒同步、首页 `RecentContentHome.swift`。

## 约束

- 16GB：构建/测试共用 `/tmp/voiceos-swift-build.lock`（mkdir 抢锁、陈旧锁按 mtime 2400 秒回收、结束 rmdir）；先 merge main。
- 不写实时库；测试用临时库；不重启应用；不 push、不合并。
- 分支 `work/m80-moreperf`，提交回报。

## 结果

- 分支：work/m80-moreperf（基于 main fac6036；`git merge main --no-edit` 退出码 0，已是最新）。
- 代码提交：ae1a9c5「perf(工作台): 处理页与行动页剩余读取改索引，dismiss 语义按访问器区分」。
- 归因：波 79 结果「遗留风险」清单第 1-3、5 项逐条对应本波改动；每处都是波 79 已实测的调用形状（每次 body 整库直算、逐行线性查、逐行过滤、按 id 全量扫描），本波按同一形状替换为索引读，并用测试内计时量化旧路径与索引读的差距。第 4 项 RecentContentIndex 未做（见「仍留的扫描点」）；MaterialManagementView 按本波可选项完成。
- 改动（5 个文件，254 增 39 删）：
  - `Sources/VoiceOSCore/RecordingContext.swift:60-64,81,104-106,125,144-150`：SourcePageIndex 在一次快照内保存 `pausedTasks`（工作台顺序、仅 task、dismissed 永不入列）、`expressionIssueBySourceID` 与全量 `allActionByID`；新增 `allAction(for:)`（含 dismissed，任务页与讨论入口用），与既有 `activeAction(for:)`（未 dismiss）命名区分；另加 `expressionIssue(for:)`。
  - `Sources/VoiceOSApp/WorkspaceProcessingView.swift:117,141`：`workspaceTaskRequiresReview` 与 `workspacePausedTasks` 改索引读（WeeklyReviewView 与 WorkspaceActivityViews 的既有调用随访问器即时受益，未改其文件）。
  - `WorkspaceProcessingView.swift:403-411`：处理页暂停任务段每次 body 只取一次 `pausedTasks`，claim 查询改 `sourcePageIndex.claim(for:)`。
  - `Sources/VoiceOSApp/WorkspaceView.swift:1902-1924`：行动页每 body 折叠一次 `ActionRowReads`（链接按 actionID、到期日取首个 linked 且非 .none、分析状态取 updatedAt 首个最大值，与逐行 `first(where:)` / `max` 语义一致）；行渲染改字典读（`WorkspaceView.swift:1931,1937,2028,1106,1187-1261`）。
  - `WorkspaceView.swift:1852`：材料行表达问题改 `expressionIssue(for:)`，不再逐行重算 digest。
  - `WorkspaceView.swift:796,2707,2720,2729`：任务页、任务讨论、行动页与搜索讨论入口改 `allAction(for:)`，dismissed 行动仍可打开。
  - `Sources/VoiceOSApp/MaterialManagementView.swift:12`：移入回收站的「连续录音段数」改索引读，不再每次求值重建目录。
  - `Tests/VoiceOSCoreTests/WorkspaceRemainingReadChecks.swift`：新增 2 项纯逻辑测试（一致性与计时）。
- 量化对照（测试内计时，400 材料、61 行动、5 轮交替取中位数）：处理页暂停任务 + 表达问题一次 body：直算 0.2093 s → 索引 0.0080 s（含一次索引构建），约 26 倍。两侧工作计数由断言锁定相等。
- 验证：build_exit=0（`swift build -j 2`，112.60 秒）；test_exit=0（`swift test -j 2`），621 项测试 0 失败（基线 619 加新增 2），37.253 秒。构建与测试共用 `/tmp/voiceos-swift-build.lock`，结束后已释放；`git diff --check` 退出码 0；未写实时库、未重启应用、未 push、未合并。
- 判据落点：
  - 判据 1：第 1-3、5 项完成，file:line 见「改动」；第 4 项 MaterialManagementView 完成，RecentContentIndex 未做（见下）。
  - 判据 2：dismiss 语义保持——`workspacePausedTasks` 与 `pausedTasks` 不含 dismissed（与直算一致：dismissed 行动 reason 恒为 nil），任务页与讨论入口用 `allAction(for:)` 返回全量；两访问器命名区分。
  - 判据 3：行为、文案、标识、键盘、选中、滚动锚点未改；索引在 `applyCoreSnapshot` 每次快照重建，无迁移。
  - 判据 4：见「验证」。
  - 判据 5：改动清单与对照见上；仍留的扫描点见下。
- 仍留的扫描点（供下一波）：
  - `Sources/VoiceOSCore/RecentContent.swift:191-238` 的 `RecentContentIndex.build` 仍每次建目录（可选第 4 项未做，文件不在本波所有权内）；调用点在 `publishHomeSnapshot` 每次快照一次，非逐行路径。
  - `WorkspaceView.swift:1382,2097,2398,2419` 仍按 id 线性扫描 actionRecords，均为一次点击或批量提交后的校验，非逐行 body 路径（波 79 同类归因）。
  - `WorkspaceProcessingView` 提醒事项异常段按 `link.id` 查 `reminderLinks`，属处理页低频异常段。
  - `WorkspaceActionPause.reason` 仍在索引构建时对每个未 dismiss 行动跑一次（O(行动数 × 含表达材料数)），与波 79 相同，含在索引构建 0.0080 s 内。
  - 测试计时是隔离 fixture 的 5 轮交替中位数，不能替代实机 sample；建议协调方用波 79 的「返回/切页」AX 口径复测行动页与处理页。
