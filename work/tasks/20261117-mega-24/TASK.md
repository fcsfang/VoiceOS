# 并行波 24：阅读连续性、行动闭环与回答可信

来源：四路只读发现（D1 阅读、D2 行动、D3 回答、D4 质感）按影响除以成本排序。本波取高影响低成本且文件互不冲突的组合；D2 的提醒断连本地完成、D3 的多轮追问、D4 的口述状态浮层留给后续波次。

## 完成判据

1. 首页记住正在读的材料：跨页面返回、跨启动都恢复到上次选中的材料与时间线位置；材料详情页记住滚动位置。
2. 材料详情页先摘要后原文；超过约 2000 字的转写默认折叠；正文行宽与首页一致；「看原话」常显可点。
3. 行动页「全部」标签顶部出现「今天 N · 逾期 N」摘要，可一键切到「我的待办」；「已完成」按完成时间倒序并在行内显示完成时间；外部已完成的待办可从行菜单确认并撤销。
4. 成功提示条 3.5 秒后自动消失，悬停暂停计时，不再永久压在窗口底部。
5. 问题详情：「重新回答」与队列「试答」产生新的分析执行，不被去重吞掉；回答状态三处（页头、行状态、回答区块）语义一致，失败的显示「回答失败」；问题详情不在「AI 的工作与交付」重复列出本问题的回答；回答区块与动作行不出现两个同名按钮；模型返回格式错误映射成中文可重试提示。
6. 菜单补齐 查找（⌘F）与「记录想法」；同类快捷键只注册一处。
7. 首次引导增加权限说明页（麦克风与提醒事项各一句收益说明），不改变系统弹窗时机。
8. 合并后 `swift build -j 2` 与 `swift test -j 2` 一次通过（405 项基础上新增）。

## 共享契约

- `AssistantExecution` 的入队函数增加 `fresh: Bool = false`：fresh 时跳过「同版本同模式已完成」的去重返回（排队中/运行中仍去重），命令身份带 fresh 标记。试答与重新回答传 `fresh: true`，其他调用保持默认。
- 行状态：`ActionRowFacts.answerState` 是最新一次分析执行的原始 state（"" 表示无记录）。`ActionRowLayout` 规则：completed → 已回答（success）；queued/running/reserved/blocked → 回答中；failed/cancelled → 回答失败（warning）；其余 → 未回答。
- 完成时间：`ActionRowFacts.completedAt` 为显示文本（"" 表示无），`ActionStore` 从 `action_revisions` 最近一次进入 completed 的修订派生；「已完成」列表按它倒序。
- 菜单：查找菜单项聚焦工作区搜索（按钮上的 ⌘F 移到菜单命令，按钮保留可读性）；「记录想法」菜单项复用现有捕获动作。
- 引导：只在 `Onboarding.swift` 内加一页说明，不主动触发系统权限弹窗。

## 单元与文件所有权

| 单元 | 分支 / 目录 | 独占文件 | 内容 |
|---|---|---|---|
| A 阅读连续性 | `work/m24-a` / `.worktrees/m24-a` | `RecentContentHome.swift`、`WorkspaceSourceView.swift` | 判据 1、2 |
| B 行动闭环 | `work/m24-b` / `.worktrees/m24-b` | `WorkspaceView.swift`、`ActionRowStatus.swift`、`ActionStore.swift`、`WorkspaceDesign.swift`、`Tests/VoiceOSCoreTests/ActionRowStatusChecks.swift` | 判据 3、4 与行状态回答失败语义 |
| C 回答与菜单 | `work/m24-c` / `.worktrees/m24-c` | `VoiceOSApp.swift`、`AssistantExecution.swift`、`QuestionAnswerSection.swift`、`WorkspaceActivityViews.swift`、`ActionClarifyQueueView.swift`、其单元测试文件 | 判据 5、6 |
| D 首次引导 | `work/m24-d` / `.worktrees/m24-d` | `Onboarding.swift` | 判据 7 |

规则同前：只在所属工作树改文件，不跑构建与测试，不碰主检出与实时库，提交到自己的分支，提交信息结尾固定一行 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 决策细节

- A：首页选中项初值读 `RecentContentHomeSelection.shared.itemID`，并用 `@SceneStorage` 持久化；时间线滚动位置与选中一起恢复。详情页「原文与回听」区在转写超过约 2000 字时默认折叠；「内容摘要」「核心要点」排到原文折叠之前。正文容器宽度改用与首页相同的 `readerWidth` 令牌（可按窗宽 clamp）。「看原话」从悬停才出现改为常显小图标按钮。
- B：摘要数字来自现有时间面数据，不新增查询；点击切到「我的待办」。完成时间从 `action_revisions` 派生，已完成列表倒序；行第二行显示完成日期。外部完成确认复用现有 `acceptReminderStatus` 与撤销栈；只在读回显示外部已完成、尚待确认的行上出现该菜单项。toast 自动消失加悬停暂停，VoiceOver 只播报一次。
- C：重新回答传 `fresh: true`；试答同样。回答区块在有完成回答时可显示「重新回答」，失败显示「重试」（现有 retry）。「AI 的工作与交付」在问题详情过滤掉本 action 的 analysis 行。错误映射：解码/结构类错误显示「AI 返回格式异常，已保留可重试」并给重试按钮，原始错误只进日志。菜单用 `CommandGroup` 增「查找…」（⌘F）与「记录想法」；删除按钮层重复快捷键注册。
- D：新页为引导第 0 页，两条各一句：麦克风用于口述与录音，提醒事项用于把待办提醒带到系统；「下一步」「跳过」行为不变。

## 验证基线

- 实时库已迁移 64：问题 43、目标 62、旁白 57、未归类 35；已完成 80、开放待办 18。
- 波 23 已把问题详情顶点换成回答区块，本波只做状态一致性、去重与去重复按钮。
