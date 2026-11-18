# 波 66 任务书（2026-11-18）：消息监测报告交互与推送收口

## 背景（只读发现 2026-11-18）

真实数据：今日报告 35 项事项全部 open/needs_check。发现的最小改进点（按困惑度排序）：

1. 事项区无筛选、分组标题无条数；35 张卡全展开，「历史报告/来源状态」被推到很后面（WorkspaceMonitorView.swift:193-210）。
2. 标记完成/不适用后条目留在原组，「事项 35 条」不变（来自 report.itemCount），页外无未处理数字（:162、:240-251；WorkspaceView.swift:580）。
3. 企业微信报文字节截断（真实报告约 9.3KB，只能发前 17/35 条，MonitorPush.swift:63/:96-108），推送不按状态过滤（MonitorCenter.swift:413-425），页脚无回看路径。
4. 空态/错误态不分：incomplete 且 0 事项显示「没有需要关注的事项」；失败报告无「去设置/重新检查」却保留「立即推送」；QQ 未添加时报告页无提示（:196、:167-170、:312-331）。
5. 证据行缺消息类型与正文片段；QQ 证据没有任何可核对入口（:262-296；MonitorCenter.swift:167-196）。

## 完成判据

1. 事项区加「未处理 / 全部」分段（默认未处理）；分组标题带条数（待核对 N、适用 N）；「全部」下已处理项收进默认折叠的「已处理（M）」组；报告头部改为「未处理 N · 已处理 M」，由事项实时状态计算，不用 report.itemCount。
2. 侧栏「消息监测」在最新报告有未处理事项时显示数字徽标（沿用行动徽标的视觉），无未处理不显示。
3. 推送只取 status=open 的事项；正文顶部一行「共 N 条，未处理 K 条」；超字节截断时追加「已省略部分事项，完整内容在应用内查看」；页脚改为「打开 VoiceOS → 消息监测 → 历史报告（YYYY-MM-DD）查看全文」。
4. 空态与失败态：incomplete 且 0 事项显示「检查不完整，可能漏项」；failed 报告把「立即推送」替换为「去设置」（切到设置页）与「重新检查」；QQ 未添加来源时来源状态区给出「未添加 QQ 群来源」及去设置入口。
5. 证据行：QQ 来源显示「QQ 群消息 · 发送人 · 时间」，无 URL 时不再出现可点击的「打开原文」；网页来源按钮文案改「在浏览器打开原文」。
6. 测试（≤3 个用例，隔离临时库/纯函数）：推送内容只含 open 事项且带计数行；截断时追加省略提示；头部未处理/已处理计数来自事项状态。中文断言。
7. `swift build -j 2` / `swift test -j 2` 真实退出码 0；当前 main 597 项测试。

## 文件所有权

- `Sources/VoiceOSApp/WorkspaceMonitorView.swift`
- `Sources/VoiceOSApp/MonitorCenter.swift`
- `Sources/VoiceOSCore/MonitorPush.swift`
- `Sources/VoiceOSApp/WorkspaceView.swift`（仅侧栏徽标最小增量）
- 对应测试
- 不碰 MessageMonitor*/MessageMonitorRunner/WebsiteMonitor/QQMonitorHelper/scripts、提醒同步、主题组织、全景、知识核查、分段理解；不加迁移。

## 约束

- 16GB：构建/测试共用 `/tmp/voiceos-swift-build.lock`。
- 不写实时库；测试隔离临时库；不重启应用。
- 分支 `work/m66-mux`，提交回报；不 push、不合并。

## 结果

- 分支：`work/m66-mux`（从 main d2bc5f4 创建）
- 构建：`swift build -j 2` exit 0（Build complete，102.81s）
- 测试：`swift test -j 2` exit 0，600 项通过，0 failures（main 597 + 新增 3）
- 改动文件：
  - `Sources/VoiceOSCore/MessageMonitor.swift`：新增 `MonitorItemTally`，未处理/已处理计数只读事项实时状态
  - `Sources/VoiceOSCore/MonitorPush.swift`：推送项携带 status 且只发 open；正文顶部「共 N 条，未处理 K 条」；截断追加「已省略部分事项，完整内容在应用内查看」；页脚带日期指向历史报告
  - `Sources/VoiceOSApp/MonitorCenter.swift`：证据行携带来源类型；推送映射保留事项状态；侧栏未处理计数读已加载状态，不逐帧查库
  - `Sources/VoiceOSApp/WorkspaceMonitorView.swift`：未处理/全部分段、分组条数、已处理折叠组、头部实时计数、失败态「去设置/重新检查」、QQ 未添加提示、QQ 证据行与网页按钮文案
  - `Sources/VoiceOSApp/WorkspaceView.swift`：消息监测侧栏数字徽标与无障碍文案
  - `Tests/VoiceOSCoreTests/MonitorPushChecks.swift`：新增 3 个中文断言用例（open 过滤与计数行、截断提示与页脚、事项状态计数）
- 未 push、未合并、未重启应用、未写实时库。
