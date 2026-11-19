# 波 100 · 任务 A：监测报告页首屏自解释与跨报告未处理可见

## 用户诉求

终核发现者以真实库证实：2026-11-19 报告 0 事项，界面显示「没有需要关注的事项」，侧栏徽标 0，但 2026-11-18 报告仍有 35 条未处理事项，跨报告不可见。推送未配置时页头仍承诺微信送达，报告卡只写「尚未推送」，报告页点「立即推送」没有就地反馈。报告卡没有生成时刻。最新报告事项读取失败会永久停在「正在读取事项…」。未处理为空且已处理大于 0 时没有提示。

## 改动

提交 1，`1ab0b27`，跨报告未处理：

1. `Sources/VoiceOSCore/MessageMonitor.swift:196-232` — 新增 `MonitorOpenItemsSummary` 纯汇总，含跨报告总数、更早报告未处理数、最早报告日期与 ID。调用方传入 `status='open'` 的查询结果，已处理事项不计入。不在最近 30 条报告列表里的旧报告仍计入更早数量，最早日期只取能拿到报告日期的项。
2. `Sources/VoiceOSCore/MessageMonitor.swift:431` — 复用既有 `openMonitorItems()`，不改查询、事项归属与迁移。
3. `Sources/VoiceOSApp/MonitorCenter.swift:633-640` — `monitorOpenItemsSummary(todayKey:)` 读取跨报告未处理，交给 Core 汇总。
4. `Sources/VoiceOSApp/WorkspaceMonitorView.swift:391-407` — 今日区新增「更早报告还有 N 项未处理（最早 日期）」提示与「展开最早的报告」入口。
5. `Sources/VoiceOSApp/WorkspaceMonitorView.swift:369-373,375-379` — 展开最早报告，统一事项加载与失败标记。
6. `Sources/VoiceOSApp/WorkspaceMonitorView.swift:70,107,224,439-464` — 页面载入、立即检查、重新检查后刷新汇总，事项完成、不适用、重新打开后也刷新。
7. `Tests/VoiceOSCoreTests/MonitorOpenItemsSummaryChecks.swift:20,33,44` — 新增 3 项测试，文件共 54 行。

提交 2，推送就绪与首屏反馈：

8. `Sources/VoiceOSApp/MonitorCenter.swift:429-432` — `monitorPushConfigured`，通道与钥匙串地址都齐全才算已配置。
9. `Sources/VoiceOSApp/WorkspaceMonitorView.swift:36,90-95` — 页头副标题按就绪状态改写，未配置时不再承诺微信送达。
10. `Sources/VoiceOSApp/WorkspaceMonitorView.swift:49,130-149` — 有报告但未配置时显示横幅「今天的报告已生成，微信推送尚未配置」与「去设置」。最近报告不是今天时文案为「最近一次报告已生成，微信推送尚未配置」。
11. `Sources/VoiceOSApp/WorkspaceMonitorView.swift:230-244` — 未配置时按钮改为「配置推送」并跳设置页，`monitorPushStatus` 渲染在按钮下方，点击后原地可见。
12. `Sources/VoiceOSApp/MonitorCenter.swift:691-694` — `monitorGeneratedText` 用 `createdAt` 解析成本地时分。`Sources/VoiceOSApp/WorkspaceMonitorView.swift:201-203` 把它加到报告卡副标题。
13. `Sources/VoiceOSApp/WorkspaceMonitorView.swift:274-286,381-385` — 最新报告事项读取失败显示「事项读取失败。」与「重新读取」按钮。页面载入、立即检查、重新检查后检查失败态。历史报告保留收起再展开的重试方式。
14. `Sources/VoiceOSApp/WorkspaceMonitorView.swift:312-318` — 未处理为空且已处理大于 0 时显示「已处理 N 项，切换「全部」查看」，已选「全部」时仍显示原空态文案。

## 测试

真实退出码，无管道，构建与测试共用 `/tmp/voiceos-swift-build.lock`：

- 提交 1：`swift build -j 2` 得到 `build_exit=0`，133.31 秒。`swift test -j 2` 得到 `test_exit=0`，`Executed 657 tests, with 0 failures (0 unexpected)`。
- 提交 2：`swift build -j 2` 得到 `build_exit=0`，34.45 秒。`swift test -j 2` 得到 `test_exit=0`，`Executed 657 tests, with 0 failures (0 unexpected)`。
- 基线 654 项，新增 3 项，共 657 项。

新增测试：

- `test今日报告为空时更早报告的未处理仍被汇总` — 今日报告为空时把更早报告的未处理计入，最早报告取日期最小值。
- `test今日未处理不计入更早计数但仍算总数` — 今天的未处理已就地展示，只从更早计数里排除，仍计入跨报告总数。
- `test不在报告列表中的旧报告仍计入更早未处理` — 超出最近 30 条报告的旧报告不被漏掉，最早日期取已知报告。

## 遗留风险

- 未做应用内实机验证。本波约束为只读、不重启应用，验证止于构建、657 项单测与代码审阅。横幅、按钮与提示的视觉和键盘行为没有实机确认。
- 侧栏徽标仍按最新报告计数（`Sources/VoiceOSApp/MonitorCenter.swift:626-629`）。本次只加今日区提示，不改徽标口径，历史未处理事项仍不进入徽标。
- `monitorPushConfigured` 每次视图求值都会同步读取钥匙串。读取量小，但与既有 `monitorWebhookTail` 一样属于主线程钥匙串查询，后续可缓存。
- 页面停留期间自动后台检查生成新报告且事项读取失败时，要等下一次载入、检查或重新进入页面才显示失败态。手动检查与页面载入这两条主要路径已覆盖。
- 设置页仍保留原有的「立即推送今日报告」按钮（`Sources/VoiceOSApp/WorkspaceMonitorView.swift:744`）。未配置时点击会得到「尚未选择推送通道」的就地反馈，本波约束不改设置页结构。