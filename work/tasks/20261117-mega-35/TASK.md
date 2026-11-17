# 并行波 35：提醒已完成待登记、完成无结果回流、静默禁用行解释

来源：发现者 B 的实时库校正（外部完成候选 25、完成无结果 78、禁用行 3 处）。全部为「有机构但用户走不通」的可见性修复。

## 完成判据

1. 处理页新增「提醒事项已完成待登记」区块：按来源分组列出现有 ExternalCompletionCandidate（约 25 条），每源一个「全部确认」按钮走既有 confirmExternalCompletion（逐条 command 幂等、版本校验）；确认后行消失、行动进已完成；区块空则不显示；计数显示在区块标题。
2. 行动页「完成后的结果」入口行显示「N 项待填结果」徽标（口径以现有 outcome follow-ups 查询为准，实测 78）；区块默认展开（有未填项时），无未填项时保持折叠。
3. 首页「任务进展」与每周回顾「本周结果」中不可用的行动行：行尾显示原因（任务已暂停 / 任务已结束），并提供「查看材料」入口并不再呈现无反应按钮；可用行行为不变。
4. swift build -j 2 与 swift test -j 2 一次通过（453 项基础上新增，如有核心逻辑）。

## 共享契约

- M1 只组合现有 confirmExternalCompletion(candidate) 通道（WorkspaceProcessingView.swift:473、VoiceOSApp.swift:3434、ExternalActionCompletion.swift:34），不新增写路径、不改核心；批量逐条调用同一函数，失败即停并显示 model.status。
- N1 徽标与展开状态用现有 outcome follow-ups 数据源（WorkspaceReadingViews 的完成后结果组件），不改 schema；「未填」定义与处理页口径一致（无当前版本 feedback）。
- O1 行禁用原因用现有状态文案（workspaceActionStatus / 暂停语义），「查看材料」走既有 openSource 通道。

## 单元与文件所有权

| 单元 | 分支 / 目录 | 独占文件 | 内容 |
|---|---|---|---|
| M1 待登记一键 | `work/m35-m1` / `.worktrees/m35-m1` | `Sources/VoiceOSApp/WorkspaceProcessingView.swift`、`Sources/VoiceOSApp/WorkspaceActivityViews.swift` | 判据 1 |
| N1 结果回流入口 | `work/m35-n1` / `.worktrees/m35-n1` | `Sources/VoiceOSApp/WorkspaceView.swift`、`Sources/VoiceOSApp/WorkspaceReadingViews.swift` | 判据 2 |
| O1 禁用行解释 | `work/m35-o1` / `.worktrees/m35-o1` | `Sources/VoiceOSApp/RecentContentHome.swift`、`Sources/VoiceOSApp/WeeklyReviewView.swift` | 判据 3 |

规则同前：只在所属工作树改文件，不跑构建与测试，不碰主检出与实时库，提交到自己的分支，提交信息结尾固定一行 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 决策细节

- M1：区块按来源分组（材料名 + 条数）；一键确认组内全部 candidate；部分失败显示第一处错误与已确认数；现有逐行按钮保留。
- N1：入口行在 WorkspaceView.swift 约 1232 行；组件在 WorkspaceReadingViews.swift 约 119-133 行；默认展开条件 = 有未填项；徽标样式沿用现有 meta 与警示色。
- O1：首页 RecentContentHome.swift 约 270-284 行任务进展行；WeeklyReviewView.swift 约 418-422 与 573-602 行「本周结果」行。

## 验证基线

- 实时库（只读）：外部完成候选 25（另 6 missing）、完成无当前结果 78、暂停行动约 30。
- 用户可能在用机器：界面实拍与重启进空闲窗口。

## 结果（完成后填）
