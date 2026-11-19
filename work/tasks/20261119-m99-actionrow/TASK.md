# 波 99 · 任务 A：行动排序与行信息的三处修正

## 用户诉求

终核发现者以真实库证实三处残留矛盾：仅有本地排期的任务在「全部」看不到日期；冲突与缺失链路的到期不参与排序，导致「提醒待核对 · 已逾期」的任务落在「随时」尾部；材料行副标题只剩日期，归属与「仅本地」藏在 .help 里，VoiceOver 与扫读不可见。

## 改动

1. `Sources/VoiceOSApp/WorkspaceView.swift:1204-1206` — 用已构建的 timeSurface 建 action→entry 映射。
2. `Sources/VoiceOSApp/WorkspaceView.swift:1254` — 「全部」列表的 actionRow 传入 timeEntry，与「我的待办」分组同一来源。
3. `Sources/VoiceOSCore/ActionTimeSurface.swift:62-67` — 新增 observed 映射，按 lastObservedAt 取最新观察，linked / conflict / missing 都算，unknown 不算。
4. `Sources/VoiceOSCore/ActionTimeSurface.swift:71-83` — 无本地排期时用最新观察的到期参与 due/day/isOverdue；needsLocalSyncLabel 仍只与 linked 链路比较，状态槽语义不变。
5. `Sources/VoiceOSApp/WorkspaceView.swift:1900-1902,1904` — 材料副标题改为「日期 · 归属[ · 仅本地]」；「分组待重新判断」保留在 .help。
6. `Tests/VoiceOSCoreTests/ActionTimeSurfaceChecks.swift` — 新增 3 项测试。

## 排序方案选择

选时间面 (a)：ActionTimeSurface 取最新观察链路，而不是让 todoOrder 在无排期时回退 reads.reminderDue。理由：时间面同时驱动「全部」排序、我的待办逾期/今天分组和顶部计数；只改视图排序回退，会让分组位置与行文字继续矛盾。收敛在一处，净改动约 8 行。副作用：无本地排期且 conflict/missing 带回读日期的任务会进入今天/逾期组，并从「安排今天」候选（只取 soon+anytime）中消失，符合「到期参与排序」的语义。

## 测试

真实退出码，无管道：

- `swift build -j 2` → `build_exit=0`（127.26s，282 步）
- `swift test -j 2` → `test_exit=0`，`Executed 651 tests, with 0 failures (0 unexpected)`（基线 648，新增 3）

新增测试：

- `testConflictDueSortsIntoOverdueGroup` — 冲突链路 11月18日到期进入逾期组并标记 isOverdue，不留在随时。
- `testMissingDueJoinsItsGroup` — 缺失链路 11月20日到期进入即将组，不算逾期。
- `testNewestObservationWinsAndUnknownDoesNotCount` — 较新的冲突观察取代较旧的 linked 观察；unknown 的最新日期不参与选择。

## 遗留风险

- needsLocalSyncLabel 仍只比较 linked 链路：本地排期加冲突/缺失回读时，状态槽仍显示「本地未同步」，meta 同时显示「提醒待核对 / 提醒缺失」。这是有意保留波 94 的状态语义，产品若要合并需另行决定。
- 「专注」分组行仍未传 timeEntry，仅有本地排期的专注项在该分组不显示日期；本次按诉求只改「全部」列表。
- 未做应用内实机验证（本波约束为只读、不重启应用），验证止于构建、单测与代码审阅。