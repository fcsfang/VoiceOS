# 波 47：通知闭环（点击、深链、最近完成、权限状态）与讨论历史列表

来源：发现者 K 提案 2/4（通知点击与设置行）与发现者 J 提案 2（讨论历史）。

## 完成判据

1. 通知默认点击有行为：带 sourceID 的通知打开材料，其余打开处理页（不再无反应）；点击即进入对应位置，不重复发同一通知（沿用现有 notification id 规则）。
2. 缺口通知补深链：导入完成/部分失败、完整转写核对完成/未完成、口述失败共 5 类带 sourceID 或处理页路由。
3. 处理页在「已全部处理」状态下也给「最近完成」5 条（类别、对象、时间），点击进入对应材料或页面；全部完成不再只是空态。
4. 设置页新增桌布通知状态行：显示授权状态（authorized/denied/未请求），denied 时给「打开系统通知设置」按钮；与提醒事项权限行同构。
5. 讨论面板给「历史讨论」入口：列出全部会话（日期、首轮摘录、状态 active/frozen、消息数），点击打开该会话继续或查看；空列表给说明。核心读取（conversations 预览）可测试。
6. swift build 与 swift test 真实退出码 0（503 基础上新增）。

## 共享契约

- NA：LocalNotice 既有授权闸门与 id 规则不动；didReceive 增加 UNNotificationDefaultActionIdentifier 分支；「最近完成」状态位用内存环形缓冲（最多 5 条）还是持久化由实现决定并报告（不新增 schema）。
- DA2：历史列表入口放讨论面板内部（sheet 或切换），不动 WorkspaceView 的入口区；核心新增会话预览查询（会话 id、创建时间、首轮摘录、状态、轮数），测试临时库夹具。
- 文件不重叠：NA 独占 VoiceOSApp.swift、WorkspaceProcessingView.swift、WorkspaceView.swift（仅设置行）；DA2 独占 WorkspaceDiscussionView.swift、ConversationStore.swift 与新建视图文件。

## 单元与文件所有权

| 单元 | 分支 / 目录 | 独占文件 | 内容 |
|---|---|---|---|
| NA 通知闭环 | `work/m47-na` / `.worktrees/m47-na` | `Sources/VoiceOSApp/VoiceOSApp.swift`、`Sources/VoiceOSApp/WorkspaceProcessingView.swift`、`Sources/VoiceOSApp/WorkspaceView.swift`（仅设置段） | 判据 1-4 |
| DA2 讨论历史 | `work/m47-da2` / `.worktrees/m47-da2` | `Sources/VoiceOSApp/WorkspaceDiscussionView.swift`、`Sources/VoiceOSCore/ConversationStore.swift`、新视图文件（如 `Sources/VoiceOSApp/DiscussionHistoryView.swift`）、`Tests/VoiceOSCoreTests/` 会话相关 | 判据 5 |

规则同前：只在所属工作树改文件，不跑构建与测试，不碰主检出与实时库，提交信息结尾固定一行 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 决策细节

- NA：K 证据——didReceive 只处理 openSourceAction（VoiceOSApp.swift:3851-3859）；通知调用点 2046、2054、2921、2924、5166、5173；处理页空态 433-436；设置段 1560-1650 无通知行；授权请求 3818-3829。
- DA2：J 证据——WorkspaceSourceView.swift:685 折叠里的「打开讨论 1..N」；ConversationStore.swift:5-11 记录无时间字段（预览查询用 user turns 首条与 created_at 推导，报告说明）；实时库 11 段会话 0 轮次，列表本期内容偏空属正常。
- 协调者纪律：构建与测试后台直跑并记录真实退出码；重启先过 scripts/app/restart_preflight.sh（当前全景在跑，闸门会拦）。

## 验证基线

- 全景一次运行中（用户发起），不得重启。
- 实时库：conversations 11（5 active / 6 frozen）；通知 6 类发点中 5 类无深链。

## 结果（完成后填）
