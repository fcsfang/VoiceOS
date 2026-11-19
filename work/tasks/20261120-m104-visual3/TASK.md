# 波 104：视觉收尾（剩余系统按钮与处理页）

## 背景

波 102 建立组件、103 覆盖主页面与弹窗后，`grep` 仍发现系统默认主按钮（未加 tint 的 `.borderedProminent` 显示为系统蓝）与零散 `.bordered` 分布在十余个文件。处理页（WorkspaceProcessingView）仍是 serif Hero 与旧卡片，未进入任何一轮视觉改造。

## 单元与文件所有权

| 单元 | 文件 | 重点 |
| --- | --- | --- |
| 104-A 处理页与活动视图 | `WorkspaceProcessingView.swift`、`WorkspaceActivityViews.swift` | Hero/卡片/时间线统一；11 处系统蓝主按钮分档 |
| 104-B 工作台残余 | `WorkspaceView.swift`、`TopicClaimConfirmViews.swift`、`RecordingTitleEditor.swift`、`RecordingInbox.swift` | 7 处 borderedProminent、确认按钮、标题编辑器、收件箱按钮 |
| 104-C 反思与讨论 | `ReflectionQuestionsView.swift`、`ReflectionGraphView.swift`、`ReflectionChangeView.swift`、`WorkspaceDiscussionView.swift`、`BilingualView.swift` | 系统蓝改主/次；图表控件保持行为 |
| 104-D 队列与卡片 | `ActionClarifyQueueView.swift`、`ReminderScheduleViews.swift`、`TopicResurfacingCard.swift` | 主次按钮、状态徽标、卡片容器 |

## 约束

- 行为、identifier、键盘、文案不变；不新增颜色字号。
- 唯一构建锁；真实退出码；TASK.md + 两次提交；不写实时库、不重启、不 push。
- 每单元完成后合并、整体构建测试，随下一次安装批次交付。