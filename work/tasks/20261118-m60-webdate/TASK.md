# 波 60 任务书（2026-11-18）：消息监测官网发布日期解析与起始过滤

## 背景（实机验收 2026-11-18 上午）

消息监测安装后首次自动检查，从计算机学院与研究生院两个真实栏目采集到 38 条通知原文（24 + 14），云端授权门禁与报告落库均按设计工作。但发现一个边界：

- 全部 `monitor_messages.sent_at` 为空，发布日期的解析没有产出结构化值。
- 来源配置的 `start_at`（默认启用当天）因此过滤不生效，列表页上的旧通知也被收进首次基线。任务书原要求「初次启用应明确起始读取范围」；现在范围偏宽，用户看到的基线不是他设定的起点。

## 完成判据

1. 列表页条目发布时间解析为 ISO 日期（`YYYY-MM-DD`）写入 `sent_at`（或等价格式，与既有排序/展示兼容）。两个真实栏目页面的实际标记都要覆盖：计算机学院 `https://cs.nuaa.edu.cn/10851/list.htm`、研究生院 `https://www.graduate.nuaa.edu.cn/2145/list.htm`（以实际抓取到的 HTML 结构为准，日期可能在 `<span>`、`.news_meta`、`.list_time` 等位置，形如 `2026-11-13`）。
2. 来源 `start_at` 过滤对可解析日期的条目生效：早于起始日期的条目不进入采集。无日期的条目仍采集，但在消息 meta 标记 `date_missing`，报告/证据里可识别为「日期待核对」，不静默丢。
3. 正文页若能解析到更精确的发布时间（如「发布时间：2026-11-13」），优先用正文页日期；解析失败回退列表页日期。
4. 既有行为不回归：URL 去重、正文转文本、失败记录、授权门禁、报告生成均不变。
5. 测试（新增 ≤3 个用例，HTML fixture 用与真实页面同构的小片段，不把整页 HTML 入库）：列表日期解析（含两种站点结构）；start_at 过滤含无日期条目；正文页日期优先。中文断言消息。
6. `swift build -j 2` / `swift test -j 2` 真实退出码 0；当前 main 581 项测试。

## 文件所有权

- `Sources/VoiceOSPlatform/WebsiteMonitor.swift`（解析与过滤）
- `Sources/VoiceOSCore/MessageMonitor.swift` 与 `MessageMonitorRunner.swift`（仅起始过滤接线所必需的最小增量）
- 对应测试
- 不碰提醒同步（`Worktrees` 里波 59 在改的文件）、主题组织、全景、知识核查、分段理解。

## 约束

- 16GB：构建/测试共用 `/tmp/voiceos-swift-build.lock`（抢锁片段见既有任务书），任何时刻只跑一个。
- 绝不读写 ~/Library/Application Support/VoiceOS；测试隔离临时库。联网只用于只读抓取两个栏目页核对结构，不写入真实资料库。
- 分支 `work/m60-webdate`，提交并回报，不 push、不合并、不重启应用。

## 结果

### 改了什么

- `Sources/VoiceOSPlatform/WebsiteMonitor.swift`
  - 列表解析在每个条目上按优先级取日期：计算机学院 `p.dd`（日）+ `p.ym`（年月）拆分节点 > 锚点后兄弟节点（限定在 `</li>` 或下一个 `<a` 之前）里的完整日期 > 锚点内完整日期 > 标题与 URL 兜底。完整日期支持 `2026-11-13`、`2026-11-13 10:20`、`2026年11月13日`。
  - 正文页新增带标签的日期解析（`发布时间：`、`发布日期：`、`时间:` 等，兼容全角冒号）；`collect` 中正文页日期优先，正文抓取失败或无标记时回退列表页日期。
- `Sources/VoiceOSCore/MessageMonitorRunner.swift`
  - 官网来源配置读取 `start_at`，采集后过滤掉发布日期早于起始日期的条目；无日期条目保留。
  - 无日期条目的 meta 写入 `date_missing: true`，不静默丢。
- `Sources/VoiceOSApp/MonitorCenter.swift`
  - 删除原先在 App 层的重复过滤包装 `MonitorStartFilteredWebsiteCollector` 与其 `startDates` 字典，过滤统一由 runner 按来源配置执行。
- 测试：新增 `Tests/VoiceOSCoreTests/WebsiteMonitorChecks.swift`（列表两种结构、正文优先与回退）；`MessageMonitorRunnerChecks.swift` 增加起始过滤与 `date_missing` 用例。共 3 个新用例，fixture 为与真实页面同构的小片段。

### 真实页面结构核对（2026-11-18 只读 curl）

- 计算机学院 `https://cs.nuaa.edu.cn/10851/list.htm`：14 条，日期在锚点内 `<div class="date"><p class="dd">13</p><p class="ym">2026-11</p></div>`，需把日与年月合并。
- 研究生院 `https://www.graduate.nuaa.edu.cn/2145/list.htm`：24 条，日期在 `</a>` 后的兄弟 `<span>2026-11-17</span>`。
- 正文页：计算机学院为 `<span>时间:2026-11-13</span>`，研究生院为 `<span>发布时间：2026-11-17</span>`。

### 测试证据

- 先红：`swift build` 退出码 0，`swift test --filter 'WebsiteMonitorChecks|MessageMonitorRunnerChecks'` 退出码 1，三个新用例按预期失败（日期为 nil、旧条目未过滤、无 `date_missing`、正文日期不生效）。
- 后绿：`swift build -j 2` 退出码 0，`swift test -j 2` 退出码 0，584 项测试 0 失败（581 基线 + 3 新增）。
- 真实页面附加核对（临时 scratch 用例，验证后删除未入库）：计算机学院 14/14 条解析出日期，首条 2026-11-13；研究生院 24/24 条解析出日期，首条 2026-10-22；两篇正文页分别解析出 2026-11-13 与 2026-11-17。

### 遗留

- `sent_at` 沿用既有 `ISO8601DateFormatter` 完整时间戳（UTC），与 QQ 消息格式一致；本地展示按日历日正确，未改为纯 `YYYY-MM-DD`。
- `start_at` 为日粒度，等于起始日期的条目会纳入；正文页日期解析依赖「发布时间/发布日期/时间 + 冒号」标记，其他站点形态需再加规则。
- 未重启应用做 UI 验收（约束内不重启、不 push）。
