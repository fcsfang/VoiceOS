# 波 45：讨论回流与入口、提醒同步异常处置

来源：发现者 J（讨论流程）提案 1、3、4 与发现者 K（通知与提醒）提案 1。K 的提案 2/4（通知点击与设置行）与 J 的历史列表排波 46。

## 完成判据

1. 讨论面板补齐成果回流：AI 回复可「保留为待核对候选」、自己的一轮可「整理为观点与行动」，复用既有 retainDiscussionCandidate / understandDiscussionTurn 通道；成果段落带「打开候选」；旧弹窗入口保留。
2. 讨论入口按当前选中项：材料、行动、搜索页的「讨论」以当前选中项开题；无选中项时禁用并提示（不再静默开出全时段会话）；全时段回顾只留给回顾页显式入口。
3. 失败与冻结：回复失败原因持久且可见（记录带 error，面板渲染 + 「重新提问」）；frozen 的进行中会话也有「结束」；面板支持 ⌘↩ 发送、Esc 收起（不落回返回导航）。
4. 处理页新增「提醒事项需要核对」区块：missing / conflict / unknown 计数与逐项显示（任务标题 + 提醒事项名），每项给「重新回读」（走既有回读通道，5120 类入口）与说明（可能已在提醒事项中被删除，保留为本地任务）；同步状态文案带异常计数；无异常时区块不显示。
5. swift build 与 swift test 真实退出码 0（490 基础上新增，如核心有变化）。

## 共享契约

- VA：不新建会话/写通道；retainDiscussionCandidate 与 understandDiscussionTurn 复用现成方法；入口解析用既有选中状态（材料/行动/搜索的 selectedItem 与 action 选中）。
- WB：只读 core 新增异常汇总查询（reminder_links 按 state 聚合 + 链接任务标题），不改写路径；「重新回读」复用既有回读触发（激活/唤醒/300 秒那条的同一函数）；不自动重建 link。
- 文件不重叠：VA 独占 WorkspaceView.swift；WB 独占 WorkspaceProcessingView.swift 与 VoiceOSApp.swift 的薄接线。

## 单元与文件所有权

| 单元 | 分支 / 目录 | 独占文件 | 内容 |
|---|---|---|---|
| VA 讨论 | `work/m45-va` / `.worktrees/m45-va` | `Sources/VoiceOSApp/WorkspaceDiscussionView.swift`、`Sources/VoiceOSApp/WorkspaceView.swift`、`Sources/VoiceOSCore/ConversationReplies.swift`、`Tests/VoiceOSCoreTests/`（会话相关） | 判据 1、2、3 |
| WB 提醒异常 | `work/m45-wb` / `.worktrees/m45-wb` | `Sources/VoiceOSApp/WorkspaceProcessingView.swift`、`Sources/VoiceOSApp/VoiceOSApp.swift`、`Sources/VoiceOSCore/RemindersStore.swift`（仅新增只读汇总）、`Tests/VoiceOSCoreTests/`（提醒相关） | 判据 4 |

规则同前：只在所属工作树改文件，不跑构建与测试，不碰主检出与实时库，提交信息结尾固定一行 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 决策细节

- VA：J 证据——两端点在 DiscussionView.swift:52-73 与 AssistantExecutionView.swift:158,243-244；WorkspaceDiscussionView.swift:49-108 只有发送/结束/整理；入口 default 分支 WorkspaceView.swift:2500-2541 走 loadReflection(distantPast, distantFuture)，图标常驻 669-672；失败文案 WorkspaceDiscussionView.swift:56,102-107，记录无 error（ConversationReplies.swift:40-48, Store.swift:63）；Esc 在 WorkspaceView.swift:372-376。实时库：11 段会话 0 轮次。
- WB：K 证据——missing 6 永久卡住（RemindersStore.swift:178-184、RemindersAccess.swift:73-87）；处置文案现为「提醒同步需要核对，保留原有尝试」无动作（WorkspaceActivityViews.swift:404-409，WB 不改该文件，区块放处理页）；回读触发 VoiceOSApp.swift:3666-3678。
- 协调者纪律：构建与测试后台直跑并记录真实退出码；重启先过 scripts/app/restart_preflight.sh。

## 验证基线

- 实时库：conversations 11（5 active / 6 frozen，0 轮次）；reminder_links linked 124 / missing 6；外部完成候选 25。
- 用户随时可能回来：重启进空闲窗口。

## 结果（完成后填）
