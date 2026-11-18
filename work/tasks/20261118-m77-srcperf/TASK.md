# 波 77 任务书（2026-11-18）：来源页主线程重算导致点入卡顿

## 背景（用户实测反馈 + 采样归因 2026-11-18）

用户反馈：首页点进某条最近想法后，要等很久才进入具体内容。

实测（16GB 本机，实时库 500+ 材料）：点击 `recent.thought` 后进程 100-205% CPU 持续约 16 秒（首次测量 38 秒，AX 轮询受忙时失真），之后回落。`sample` 归因：2098 个主线程样本中 1865 个在 `WorkspaceSourceView.body.getter` → `readingScrollView` → `pausedActions` → `actions` → 对目录里每份材料调用 `SourceRecord.recordingExpression(in:)`，其中稠密计算 `RecordingExpression.digest`（对成员材料取哈希/拼接）。即主线程在 SwiftUI body 里做 O(材料数 × 表达式计算) 的全量扫描，且随每次布局重复；辅以 `initializeWithCopy for SourceRecord` 热符号（重结构体反复拷贝）。

## 完成判据

1. 来源页渲染不再在主线程做全量扫描：`actions`、`pausedActions`、`recordingExpression(in:)` 涉及的每次 body 求值改为查 O(1) 索引或每数据版本一次的缓存结果。
   - 推荐形态：在模型层维护「sourceID → RecordingExpression」「sourceID → 关联 actions」索引（records/actions 变更时重建一次，model 层 @Published 或惰性重建），视图 body 只读。
   - 或视图层用 `.task(id:)` 生成 `SourcePageFacts`（expression、actions、pausedActions、context 等）存入 @State，body 只读快照。任选其一，以最小 diff 为准。
2. 首屏行为不变：内容、按钮、滚动定位、暂停/恢复逻辑、标识与文案不改；数据变化（材料/观点更新）后事实仍能刷新。
3. 量化验证：新增测试（≤2，纯逻辑）锁定索引结果与直算一致（同一 fixture 下 expression/actions 集合相等）；报告里给出修复前后对照（用同一操作路径：点击 recent.thought 至 CPU 回落 <30% 的实测可能需协调方做，代理至少用测试内计时证明计算量从 O(材料数²) 降为 O(材料数)）。
4. `swift build -j 2` / `swift test -j 2` 真实退出码 0（先 merge main，基线 615 项）。
5. 顺手检查：`WorkspaceSourceView` 内其他 body 路径中的同类全量扫描（如 `catalog` 字典每帧重建、`claims.first(where:)` 循环）若同属主线程热点，一并按同法处理，但每处都要有归因依据，不盲改。
6. 不改数据语义、不加迁移、不碰消息监测/QQ/提醒同步；不影响波 74-76 的卡片样式。

## 文件所有权

- `Sources/VoiceOSApp/WorkspaceSourceView.swift`（主体）
- `Sources/VoiceOSApp/VoiceOSApp.swift` 或模型所在文件（若引入索引）
- `Sources/VoiceOSCore/RecordingContext.swift` / `RecordingExpression.swift`（仅当索引需要，保持公开语义）
- 对应测试
- 不碰其他文件。

## 约束

- 16GB：构建/测试共用 `/tmp/voiceos-swift-build.lock`（mkdir 抢锁、陈旧锁按 mtime 2400 秒回收、结束 rmdir）；先 merge main。
- 不写实时库；测试用临时库；不重启应用；不 push、不合并。
- 分支 `work/m77-srcperf`，提交回报。

## 结果

- 分支：work/m77-srcperf（基于 main e347ab3；`git merge main --no-edit` 退出码 0，已是最新）。
- 代码提交：4e21226「perf(来源页): 主线程改读来源页索引，去掉每次布局的全量扫描」。
- 归因复核：`sample` 的 2098 个主线程样本中 1865 个在 `WorkspaceSourceView.body.getter`；pausedActions 775、actions 1832（含子帧）、catalog 675、`SourceRecord.recordingExpression(in:)` 2145（含子帧）、`RecordingExpression.digest` 1035、`initializeWithCopy for SourceRecord` 216。读码确认 body 每次求值都重建 catalog（每处访问一次，sample 中约 8 处）、对每份材料校验 digest，并对每条行动调用 `WorkspaceActionPause.reason` 扫描 records、claims 与 actionRecords（`WorkspaceSourceView.swift:92-96,231-234,267`；`WorkspaceActionPause.swift:15,36-41`）。`applyCoreSnapshot` 是五组数组唯一的赋值点（`VoiceOSApp.swift:1478-1489`），`ControlCenter` 为 `@MainActor`，方法体内无 await。
- 改动（4 个文件，245 增 13 删）：
  - `Sources/VoiceOSCore/RecordingContext.swift:51-136`：新增 `SourcePageIndex`，一次构建 `recordsByID`、sourceID → 已校验连续表达、sourceID → 关联行动 ID（保持 actionRecords 顺序）、actionID → 是否待核对（复用 `WorkspaceActionPause.reason`，只传入含表达的 sources 与本行动自己的 claim、actions，语义等价），查询为字典查找。
  - `Sources/VoiceOSApp/VoiceOSApp.swift:810,1491-1493`：`ControlCenter` 保存 `sourcePageIndex`，在 `applyCoreSnapshot` 写完 ledgers 后同步重建一次。
  - `Sources/VoiceOSApp/WorkspaceSourceView.swift:92-95,103,114,231-233,266,283,333,529,689,771,1010`：catalog、expression、actions、pausedActions、历史行动过滤、节目配对与引用按 id 查记录改为读索引。
  - `Tests/VoiceOSCoreTests/PausedActionBatchPlanChecks.swift:234-378`：新增两个测试，`testSourcePageIndexMatchesDirectReads` 锁定索引与直算（表达、行动集合、待核对判定）一致；`testSourcePageIndexReadsDoNotRescanTheLibrary` 用同一读取路径计时。
- 量化对照：测试内计时，400 份材料、400 条观点、120 条行动，40 轮模拟 body 读取（每轮 3 份材料，表达 8 次、行动 3 次、暂停行动 5 次，倍率取自 sample）：直接计算 0.388 s，索引查询 0.0028 s（索引构建 0.0013 s），约 136 倍；两侧读取的结果计数相等（断言）。复杂度上，旧路径每个 body 求值为 O(材料数 + 页行动数 × 材料数)，新路径查询 O(表达成员数 + 页行动数)，全量工作只在新快照时做一次。
- 验证：build_exit=0（`swift build -j 2`，111.05 秒；评论清理后增量重建 11.03 秒、退出码 0）；test_exit=0（`swift test -j 2`）617 项测试 0 失败（基线 615 加新增 2），33.87 秒，评论清理后复跑 33.54 秒仍 0 失败。构建与测试共用 `/tmp/voiceos-swift-build.lock`，结束后已释放；`git diff --check` 退出码 0。
- 判据落点：
  - 判据 1：来源页的 catalog、expression、actions、pausedActions 与按 id 查记录均为索引读，不再随 body 求值做全量扫描。
  - 判据 2：首屏内容、按钮、滚动定位、暂停/恢复逻辑与文案未改；索引每次 `applyCoreSnapshot` 重建，材料或观点变化后事实会刷新；行动顺序与直算一致由测试锁定。
  - 判据 3：新增 2 个纯逻辑测试；对照计时见上。实机点击路径耗时留给协调方安装后复测。
  - 判据 4：见「验证」。
  - 判据 5：`programPairs`、`contextReadKey`、`pendingUnderstanding` 仍按记录过滤，但 sample 中只有 42、32 个包含样本，无独立热帧，按最小 diff 未改。`workspaceActionStatus` 等行内文案仍会触发 `recordingActionRequiresReview` 的整库扫描，sample 未归因，未改。
  - 判据 6：未改数据语义，无迁移，未碰消息监测、QQ、提醒同步与波 74-76 卡片样式。
- 遗留风险：
  - 索引只在 `WorkspaceSourceView` 使用；`WorkspaceView`、`MaterialManagementView`、`RecentContentIndex` 仍各自建目录，属本轮文件所有权之外。
  - `recordingExpressionIssue(in:)` 在多段表达时仍会重新计算 digest，每次 body 一次，规模为表达成员数而非材料数。
  - 索引构建增加一次 O(可达行动数 × 含表达材料数) 的待核对计算；400/120 fixture 上为 1.3 ms。
  - `sourcePageIndex` 与 `records` 的一致性靠 `applyCoreSnapshot` 单一写入点维持，和现有 `homeSnapshot` 同一约定；`records` 未收紧访问级别。
  - 实机点入耗时未复测；测试计时是隔离 fixture 的单次运行，不能替代真机 sample。
