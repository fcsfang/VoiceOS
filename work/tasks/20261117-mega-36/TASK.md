# 波 36：刷新作用域（交互不再等全链）

来源：发现者 C（波 34）实测一次全刷新 3.4-5.7 秒，其中首屏 core 仅 133-152ms；交互后 await refresh() 一直等到全链跑完。快照层已有 full/core/secondary/assistant/knowledge 五作用域，应用层刷新全部请求 full。

## 完成判据

1. VoiceOSApp 的 refresh 增加作用域参数（默认 `.interactive`）；交互路径默认只加载核心与次段（core+secondary），不再阻塞于助理、跟进有效性、知识核查、讨论与静默回顾、尾段。
2. 全量路径保留并用于：启动、应用激活、60 秒定时器、显式要求全量的站点；这些行为与今天完全一致。
3. 需要即时报数或即时状态的站点显式选择作用域（至少：发起/追问助理分析后要看到排队与运行状态的站点；保存讨论后要看到会话列表的站点；重试知识核查后要看状态的站点；重试跟进后要看回执的站点）。审计出的清单写进报告，每处给出 file:line 与选用的作用域。
4. 面板打开时的既有补刷路径不删；若某面板今天没有补刷，补一个最小 .task 拉取。
5. 无行为回归：swift build -j 2 与 swift test -j 2 一次通过（453 项基础上新增作用域语义测试）。

## 共享契约

- 核心新增 `WorkspaceSnapshotScope.coreSecondary`（wantsCore 与 wantsSecondary 为真，其余为假）；不改变现有 case 语义。
- 应用层 `RefreshScope`：`.interactive`（core+secondary）、`.full`（今天行为）、`.assistant`、`.knowledge`（映射到快照作用域并在刷新后重发对应段）。refresh 默认值 = `.interactive`。
- 讨论与静默回顾段只在 `.full` 里加载；保存讨论的站点用 `.full` 或专门段（二选一，报告里说明理由）。
- 不新增 schema；不改 Store 层查询本身。

## 单元与文件所有权

| 单元 | 分支 / 目录 | 独占文件 | 内容 |
|---|---|---|---|
| S1 刷新作用域 | `work/m36-s1` / `.worktrees/m36-s1` | `Sources/VoiceOSApp/VoiceOSApp.swift`、`Sources/VoiceOSCore/WorkspaceSnapshot.swift`、`Tests/VoiceOSCoreTests/`（快照相关）、以及调用点最小编辑：`ActionClarifyQueueView.swift`、`UndoSupport.swift`、`ActionUndoControl.swift`、`ReverifyControls.swift`、`WorkspaceActivityViews.swift` | 判据 1-5 |
| D2 只读发现 | 无工作树 | 无 | 波 37 候选：首页线索与复盘回路（见下） |

## 决策细节

- S1：先读 VoiceOSApp.swift 的 reloadWorkspace/refresh 与 C 报告的段清单（assistantSnapshot、followupValidity、knowledge、discussion、quiet、尾段）；把「刷新」拆成段函数，按 scope 组合；`.interactive` 完成后立即发布，助理等段由定时器与激活兜底，迟到数据不得覆盖新数据（注意与波 30 的冻结语义：contextValidityChanged 时下一轮 full 纠正）。
- S1：180 个 `await refresh()` 调用点保持不动，只在审计出敏感站点改显式 scope；审计清单进报告。
- D2：只读；覆盖首页「最近」时间线与线索分组的现状（RecentContentHome、RecentContentDigest、RecentContentIndex），找 3-5 个最小改进（线索重命名与合并、跨材料最近想法聚合、无想法来源的整理入口），每条带 file:line、成本、影响；不写文件。

规则同前：只在所属工作树改文件，不跑构建与测试，不碰主检出与实时库，提交信息结尾固定一行 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 验证基线

- 交互后刷新目标：从 3.4-5.7 秒降到核心两段（热态约 0.5-1 秒，trace 实测 secondary 312-864ms）。
- 60 秒定时器与激活事件保留全量（VoiceOSApp 约 2995 行）。

## 结果（完成后填）

## 结果（2026-11-17 下午）

- S1 合并：核心新增 `WorkspaceSnapshotScope.coreSecondary`；应用层 `RefreshScope`（默认 `.interactive`、`.full`、`.assistant`、`.knowledge`）；敏感站点显式作用域约 30 处（助理 16、知识 5、讨论 4，保存讨论走 `.interactive` 后接专门 `refreshDiscussion()`）；面板补刷三处（助理面板 `.assistant`、任务详情与澄清队列默认）。
- swift build -j 2 通过；swift test -j 2 454 项 0 失败（453 基础上新增作用域语义 1 项）。
- 隔离副本实测：待核对「跳过」交互触发的刷新快照读取 306.2ms、发布完成约 0.5 秒，trace 交互段无 assistant / validity / knowledge 标记；对照启动全量 7.18 秒。60 秒定时器、激活事件、启动保持 `.full`。
- 已知边界：followupValidity 与知识核查在两轮全量之间最多陈旧 60 秒；`.assistant` 产生冻结标志时本轮不重发核心，下一轮全量纠正（与波 30 语义一致）。
