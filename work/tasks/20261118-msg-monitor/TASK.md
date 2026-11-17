# 波 56 任务书（2026-11-18）：每日消息监测

## 背景（用户 2026-11-18 任务书）

用户曾因不看 QQ 班级群错过一个申请即可获得的特别奖学金。目标：VoiceOS 内置每日消息监测，汇总「南航16院2025级硕士生」QQ 群与计算机学院、研究生院官网新增通知，用已有模型连接识别用户需要关注的事项，在 VoiceOS 内查看跟进，并推送微信每日汇总。每天自动检查一次，这是用户希望的最高频率。

已验证事实（不得夸大）：
- qqnt-export-macos（commit 5a061fbf…，0.4.0）可用；`LiveDatabaseMirror` 复制运行中 QQ 的 DB/WAL，`QQRecentReader` 只读查询。
- 原 QQ 最小化时，独立 Python 程序实时收到手机互传三条测试标记（00:07 时段），记录次数各 1；班级群自然新消息实时接收尚未验收；图片、附件、长时间离线补读未验收。
- 首次准备已由用户完成（扫码两次）；日常读取不需重复扫码或 LLDB。不得擅自重新签名原 QQ、关闭 SIP 或登录其他实例。
- 验证材料在 `~/01 Projects/Orange-Improve/message-radar/out/qqnt-validation/`（密钥 0600、probe-config.json 含 account 与目标群）。密钥、数据库副本、群 ID 原文不上传、不入 Git、不打印。

## 架构决定

1. **独立通知域**。新表承载来源/消息/游标/报告/事项，不写 claims、knowledge、actions、个人画像。群友的个人表达不构成用户的任务。
2. **QQ 采集**走 VoiceOS 管理的短生命周期 Python 辅助：仓库内自研脚本 `scripts/qqmonitor/qq_read_range.py`，引用已安装的 `qqnt_export_macos`（不复制其源码），stdin/stdout JSON 交接；使用 `export_chatlab_range` 做精确时间区间全量读取。Python 解释器路径、密钥路径、账号、群在设置中绑定，不硬编码。
3. **官网采集**在 Swift 侧：URLSession 抓栏目列表页与正文，轻量 HTML 转文本，按 URL 去重，保留标题/链接/发布时间/正文。
4. **分析端口**：新 `ResponsesNotificationAnalysisPort`，提示词版本 `message-monitor-daily-v1`，输入为指定来源新增消息 + 已有未完成事项 + 来源状态；输出结构化 JSON（报告标题/摘要、事项列表：标题、关联原因、建议行动、截止时间与原文依据、适用条件、来源引用、不确定项、关联已有事项、分类 applicable/needs_check）。超过预算分批并合并，不静默截断、不做关键词过滤。图片/附件/合并转发标「待查看」。
5. **推送**：通用 webhook 通道，支持企业微信群机器人（qyapi.weixin.qq.com markdown）与 Server酱式（sctapi.ftqq.com）两种报文体；URL 属凭据，走本机 Keychain 存储；预览、测试、失败重试、投递状态（pending/delivered/failed）落盘。
6. **调度**：每日一次，时间可配置（默认 09:00），启动/唤醒补跑，同日不重复分析或推送；「立即检查」仅手动触发。不安装 LaunchAgent；应用退出后不运行的事实如实展示，下次启动补跑。
7. **云端授权**：QQ 群内容配独立开关（默认关），不继承录音授权；密钥与整个数据库永不进入模型上下文。

## 单元划分

- **单元 A（core）**：schema 73 迁移；`MessageMonitor.swift`（来源/消息/游标/报告/事项存储与去重合并）；QQ 辅助脚本与运行器（含诊断）；官网抓取器；分析端口；日报生成编排（不含 UI）；点击测试。
- **单元 B（UI/调度/推送）**：消息监测页面与设置、每日调度接线、webhook 推送与 Keychain、诊断展示、处理页注意力接入。

## 完成判据（映射用户验收）

1. 能绑定密钥路径与目标群、读取展示来源；缺依赖/密钥失效有可操作中文诊断，不自动改 QQ 或安全设置。
2. 采集链路用设备互传新标记可验证；群自然新消息验收留本机用户配合（不向真实群发测试）。
3. 跨日补跑、重叠窗口、去重、模型/推送失败恢复，不漏不重复。
4. 模型跨消息提取事项并给原文出处；他人表达不变成用户任务；资格/日期不明标待核对。
5. 应用内可看报告、原文与事项状态；每日一次，同日重开不重复生成报告。
6. 微信实收留用户绑定后验收；未完成前不标完成。

## 约束

- 16GB：全局同一时刻只跑一个 swift build/test，共用 mkdir 锁 `/tmp/voiceos-swift-build.lock`。
- 绝不写实时库 `~/Library/Application Support/VoiceOS`；测试隔离临时库。
- 构建/测试只认真实退出码，不用管道取 `$?`。
- 分支 `work/m56-monitor`，PR 合并；不碰其他波次文件。

## 单元 A 结果

**改动**
- `Sources/VoiceOSCore/Database.swift`：迁移 74 新建通知域 5 张表与 3 个索引；版本上限改为 74。按协调者更正，73 归波 53（处理页失败出口）；本迁移接受 72 或 73 并以 74 为完成标记，合并时波 53 的 72→73 块必须位于本块之前。
- `Sources/VoiceOSCore/MessageMonitor.swift`：来源、消息、游标、报告、事项的域类型与存储；按 (source_id, external_id) 去重；游标记录 last_success_end 与 last_run_message_ids（消息行 id）；报告按 report_date 唯一 upsert；事项命中 related_existing_item_id 时原地更新并保留用户状态（done/dismissed）与 first_seen_date，不新建重复行；跨报告移动事项时同时重算两个报告的 item_count。
- `Sources/VoiceOSCore/ResponsesNotificationAnalysisPort.swift`：新分析端口，promptVersion `message-monitor-daily-v1`，schemaVersion `message-monitor-items-v1`；单次请求、无工具、严格 JSON；分批预算 40000 字符，多批后仅一次合流调用；校验原文依据（归一化子串或二元组重叠 ≥ 0.8）、来源引用、关联事项与截止日期格式；合流结果按来源引用覆盖校验，遗漏即拒绝保存。
- `Sources/VoiceOSCore/MessageMonitorRunner.swift`：`runDailyCheck(date:)` 与 `retryAnalysis(reportDate:)`；重叠窗口 30 分钟，首次回看 24 小时；来源失败记 incomplete 并写 last_error；分析失败保存原文与 failed 报告且游标已推进；同日重跑更新同一报告，无新消息且报告完整时不重复分析。
- `Sources/VoiceOSPlatform/QQMonitorHelper.swift`：Process 调用用户 Python 与仓库脚本，JSON stdin/stdout，默认 300 秒超时；诊断区分解释器缺失、脚本缺失、缺 qqnt-export-macos、密钥无效、QQ 数据目录缺失；脚本错误码映射为可操作中文诊断。
- `Sources/VoiceOSPlatform/WebsiteMonitor.swift`：串行抓取栏目与正文，间隔 0.5 秒；同源文章链接保守解析（/20xx/、/info/、/content/、c<digits>a<digits>、三位以上数字路径），正文复用 ArticleExtractor，单条文章失败不丢列表结果。
- `scripts/qqmonitor/qq_read_range.py`：umask 077，stdin 版本化 JSON，调用 qqnt_export_macos 的 QQRecentReader 与 export_chatlab_range；输出稳定 JSON 契约；错误时 stderr 单行 JSON（code/zh/en）并非零退出；只读，不打印密钥。

**表结构（迁移 74）**
- monitor_sources(id, kind CHECK('qq-group','website-column'), display_name, config_json, enabled, created_at, updated_at)
- monitor_messages(id, source_id FK, external_id, kind CHECK('text','image','file','forward','article','other'), sender_name, sent_at, collected_at, content, content_sha256, meta_json, UNIQUE(source_id, external_id))
- monitor_cursors(source_id PK FK, cursor_json, last_success_at, last_error, updated_at)
- monitor_reports(id, report_date UNIQUE, state CHECK('complete','incomplete','failed'), headline, summary, source_status_json, item_count, created_at, delivered_at, delivery_state CHECK('pending','delivered','failed') DEFAULT 'pending', delivery_error, payload_json)
- monitor_items(id, report_id FK, title, why_relevant, suggested_action, deadline_text, deadline_date, conditions, evidence_quote, source_refs_json, uncertainty, category CHECK('applicable','needs_check'), status CHECK('open','done','dismissed') DEFAULT 'open', related_item_id, first_seen_date, last_updated_date, created_at, updated_at)
- 索引 monitor_message_source_time、monitor_item_report、monitor_item_status。

**测试证据**
- `swift build -j 2` exit 0；`swift test -j 2` exit 0；557 项测试，0 失败（/tmp/m56a-build.log、/tmp/m56a-test.log，2026-11-18 01:02）。
- 新增 4 个检查文件共 18 项且全部通过：MessageMonitorStorageChecks 4（迁移 74、来源 CRUD、去重重放、关联更新保留 done/dismissed）、NotificationAnalysisChecks 5（原文依据/来源引用/关联校验、单批一次调用、两批加一次合流）、MessageMonitorRunnerChecks 5（无消息 complete、来源失败 incomplete、跨日重叠去重、分析失败保留原文与游标并只重分析成功、QQ 失败不丢官网结果）、QQMonitorChecks 4（自造 fixture 解码契约、图片与合并转发待查看、脚本静态编译、错误 JSON 契约）。
- 脚本侧另行验证：py_compile 通过；本机 /usr/bin/python3 未安装 qqnt-export-macos 时，stderr 输出 import_failed JSON 且 exit 2（手工运行，不连真实密钥）。

**给单元 B 的接口**
- 存储（VoiceOSStore 扩展）：`addMonitorSource(kind:displayName:configJSON:enabled:) -> MonitorSource`、`updateMonitorSource(id:displayName:configJSON:enabled:)`、`removeMonitorSource(id:)`、`monitorSources()`、`enabledMonitorSources()`、`insertMonitorMessages(_:) -> [MonitorMessage]`、`monitorMessages(ids:)`、`monitorCursor(sourceID:)`、`advanceMonitorCursor(sourceID:lastSuccessEnd:newMessageIDs:)`、`failMonitorCursor(sourceID:error:)`、`upsertMonitorReport(date:state:headline:summary:sourceStatus:payloadJSON:) -> String`、`applyMonitorAnalysis(reportID:date:items:) -> Int`、`monitorReport(date:)`、`latestMonitorReport()`、`monitorReports(limit:)`、`monitorItems(reportID:)`、`openMonitorItems()`、`setMonitorItemStatus(id:status:)`。
- 编排：`MessageMonitorRunner(store:analysis:qqCollector:websiteCollector:qqSettings:now:)`、`runDailyCheck(date:) -> MonitorRunResult`、`retryAnalysis(reportDate:) -> MonitorRunResult`。
- 采集：`QQMonitorSettings(pythonPath:scriptPath:keyPath:cacheDir:account:timeout:)`、`QQMonitorCollecting.collect(conversationID:start:end:settings:)`、`QQMonitorHelper.collect(...)` 与 `diagnose(settings:) -> QQMonitorDiagnosis`；`WebsiteMonitorCollecting.collect(columnURL:)`、`WebsiteMonitor(fetchHTML:)`、`MonitorListParser.articleLinks(html:baseURL:)`。
- 分析：`NotificationAnalysisPort.analyze(_:)`、`ResponsesNotificationAnalysisPort(baseURL:apiKey:model:transport:deadline:)`、`NotificationAnalysisInput/Result/Item`、`NotificationAnalysisValidation.validate(_:input:messages:)`。
- 域类型：`MonitorSource`、`MonitorSourceKind`、`MonitorMessageDraft/Message/Kind`、`MonitorCursor`、`MonitorReport/State`、`MonitorSourceStatus`、`MonitorItem/Category/Status`、`MonitorRunResult`。

**遗留**
- 真实 QQ 群读取、图片/附件与长时间离线补读仍未验收，需用户在本机配合；本单元只以自造 fixture 与错误契约验证，不连真实密钥。
- 合并顺序要求：波 53 的 72→73 迁移块必须先于本通知域块执行，否则全新库会跳过其列变更；本块接受 72/73 仅为分支自洽。
- `retryAnalysis` 依赖游标中的 last_run_message_ids；若同日的新采集覆盖了游标，只重分析会返回可操作错误，需要等下一次每日检查。
- 分析分批预算为 40000 字符常量；图片、文件、合并转发仅以「待查看」占位参与分析，真实内容需用户打开查看。
- payload_json、delivery_*、Keychain 与 webhook 属单元 B；本单元不写 UI、不调度、不推送。
- 官网解析按通用规则保守处理，未对真实 cs.nuaa.edu.cn / graduate.nuaa.edu.cn 页面联网验证。
