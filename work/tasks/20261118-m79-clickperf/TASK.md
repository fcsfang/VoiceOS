# 波 79 任务书（2026-11-18）：全局点击路径的目录重建与逐行扫描

## 背景（用户反馈 + 实测 2026-11-18）

用户反馈「整个软件的按钮点击都有一定性能问题，比如返回」。实测（当前安装版，含波 77）：导航切换 0.23-0.35s 尚可；**返回按钮 2.03s 才回到内容可见**。波 77 已证实同类病灶：`WorkspaceSourceView` 每次 body 重建 catalog、逐材料算 digest，主线程按 16 秒。波 77 的结果明确列出未覆盖的部分：`WorkspaceView`、`RecentContentHome` 仍在每次求值里扫描 `model.records` / `model.claims`。

已具备的条件：波 77 的 `SourcePageIndex`（`RecordingContext.swift`）已在 `ControlCenter.sourcePageIndex` 每次 `applyCoreSnapshot` 构建一次，含 `recordsByID` 与按 source 的表达/行动索引。

## 完成判据

1. `WorkspaceView.swift` 内高频 body 路径不再逐行全量扫描：
   - `recordCatalog` 等每帧重建的 `Dictionary(uniqueKeysWithValues: model.records...)` 改为复用 `model.sourcePageIndex` 的 recordsByID（或同一次快照构建的等价索引）。
   - `model.records.first(where:)`、`model.claims.first(where:)`、`model.actionRecords.first(where:)` 等出现在行渲染/点击处理里的按 id 查询，改为字典查；非热路径可不改（要有归因依据）。
2. `RecentContentHome.swift`：最近想法/时间线行渲染中按 `sourceIDs` 查记录（`materialSource` 等）改为索引读；`rowTitle/rowMeta/statusSlot` 保持行为不变。
3. 返回与切页路径的实测改善：代理无法安装 dist，但要给出测试内计时对照（模拟返回后首页行渲染读取的总次数/耗时，旧逐行扫描 vs 索引读），并明确交给协调方用同一「返回」口径复测。
4. 行为与文案零变化；键盘导航、选中、标识、滚动锚点不动；不加迁移。
5. `swift build -j 2` / `swift test -j 2` 真实退出码 0（基线 617 项）；如需为索引扩展写测试（≤2 个，纯逻辑，中文断言）。
6. 各改动点给出 file:line 清单与归因（哪条 sample/测量支撑）。

## 文件所有权

- `Sources/VoiceOSApp/WorkspaceView.swift`
- `Sources/VoiceOSApp/RecentContentHome.swift`
- `Sources/VoiceOSCore/RecordingContext.swift`（仅当索引需扩展，保持向后兼容）
- 对应测试
- 不碰 `WorkspaceSourceView.swift`、消息监测、QQ、提醒同步。

## 约束

- 16GB：构建/测试共用 `/tmp/voiceos-swift-build.lock`（mkdir 抢锁、陈旧锁按 mtime 2400 秒回收、结束 rmdir）；先 merge main。
- 不写实时库；测试用临时库；不重启应用；不 push、不合并。
- 分支 `work/m79-clickperf`，提交回报。

## 结果

- 分支：work/m79-clickperf（基于 main 68c89b0；`git merge main --no-edit` 退出码 0，已是最新）。
- 代码提交：60c0319「perf(工作台): 点击与返回改读来源页索引，去掉行渲染里的全量扫描」。
- 归因：波 77 的 sample 把 1865/2098 个主线程样本归到 `WorkspaceSourceView.body` 的目录重建、逐材料 `recordingExpression(in:)` digest 与逐行动 `WorkspaceActionPause.reason` 直算；波 77 结果列明 `WorkspaceView` 与 `RecentContentHome` 未覆盖，本波实测给出返回 2.03 s。本波按同一调用形状逐处替换，并用测试内计时量化旧路径与索引读的差距（见下）；无归因的点击未做全量改写。
- 改动（4 个文件，235 增 32 删）：
  - `Sources/VoiceOSCore/RecordingContext.swift:55,75,117,121`：SourcePageIndex 保存 claimByID，新增 `claim(for:)`；把未 dismiss 的 actionByID 暴露为 `activeAction(for:)`（Comment Sicko 复查后由 `action(for:)` 改名，注释删除）。
  - `Sources/VoiceOSApp/WorkspaceView.swift:1848`：`recordCatalog` 由每次 body 重建字典改为读 `recordsByID`。
  - `WorkspaceView.swift:860-869,887,1850,1823-1830`：`distinctExpressions`、`materialRows`、`sourceRow`、`sourceNavigationTitle` 的表达校验改读 `expression(for:)`，材料页与主题页不再对每份材料重跑 digest。
  - `WorkspaceView.swift:1414,1424,1426,1926`：行动页筛选与行状态的待核对判定改读 `requiresReview`，去掉每行 `WorkspaceActionPause.reason` 整库直算。
  - `WorkspaceView.swift:720,722,778,783,994,1512,1611,1790,1951-1953,2688,2690,2701,2710,2716`：页级、行级与点击路径的按 id 查记录或观点改字典读。
  - `Sources/VoiceOSApp/RecentContentHome.swift:229,335,355-356,469`：`materialSource`、进度行材料判断、任务不可用原因、原话入口改索引读。
  - `Tests/VoiceOSCoreTests/WorkspaceClickReadChecks.swift:82,106`：新增 2 项纯逻辑测试。
- 量化对照（测试内计时，500 材料、500 观点、61 行动，5 轮交替取中位数；两侧工作计数由断言锁定相等）：
  - 首页行读取（每项两次记录查找、进度行材料判断、3 条待核对判定）：直扫 0.0517 s → 索引 0.00020 s，约 258 倍。
  - 材料页一次 body（按 8 次读取模拟目录重建与逐材料表达校验）：直算 0.0334 s → 索引 0.0076 s（含一次索引构建），约 4.4 倍。
  - 实机「返回」2.03 s 的复测留给协调方用同一 AX 口径验证。
- 验证：build_exit=0（`swift build -j 2`）；test_exit=0（`swift test -j 2`），619 项测试 0 失败（基线 617 加新增 2），33.358 秒。Comment Sicko 复查后仅做重命名与注释删除，按约束重新构建与测试，build_exit=0、test_exit=0，619 项 0 失败。构建与测试共用 `/tmp/voiceos-swift-build.lock`，结束后已释放；`git diff --check` 退出码 0。
- 判据落点：
  - 判据 1：WorkspaceView 的目录、表达、待核对与按 id 查询均为索引读。保留的线性查询有归因：796/1381/2081/2382/2403/2691/2704/2713 依赖 dismissed 行动语义（索引只含未 dismiss 行动），2585 是每次深链一次性的存在性检查。
  - 判据 2：RecentContentHome 的按 id 读取改索引；`rowTitle`/`rowMeta`/`statusSlot` 的文案与判定未改。
  - 判据 3：测试内计时见上；实机复测交给协调方。
  - 判据 4：行为、文案、标识、键盘、选中与滚动锚点未改；索引在 `applyCoreSnapshot` 每次快照重建，无迁移。
  - 判据 5：见「验证」。
  - 判据 6：file:line 见「改动」与「归因」。
- 遗留风险（供后续波次）：
  - 未覆盖的扫描点：
    - `WorkspaceProcessingView.swift:117,143` 的 `workspaceTaskRequiresReview` / `workspacePausedTasks` 仍整库直算；`WorkspaceView.swift:1181` 每次 body 调 `workspacePausedTasks`，行动页仍有 O(行动数 × 材料数) 项。
    - `WorkspaceView.swift:1854` 的 `recordingExpressionIssue(in:)` 对多段表达仍重算 digest，每次 body 一次（波 77 遗留）。
    - `WorkspaceView.swift:1908` 逐行查 reminderLinks，`latestAnalysisState` 每行过滤 assistantExecutions（1390-1393）。
    - `MaterialManagementView` 与 `RecentContentIndex` 仍各自建目录（波 77 遗留清单）。
    - 796/2691 的任务页与讨论入口需要查 dismissed 行动；索引化需保存全量 actionByID。
  - 索引与 records/claims/actions 的一致性继续靠 `applyCoreSnapshot` 单一写入点；索引构建包含一次 O(行动数 × 含表达材料数) 的待核对计算，500 材料 fixture 上含在 0.0076 s 内。
  - 测试计时是隔离 fixture 的 5 轮交替数据，不能替代实机 sample。
