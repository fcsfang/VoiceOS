# 波 103：视觉系统第二圈（弹窗与次级页面）

## 背景

波 102 统一了首页、材料、行动、设置、监测、主题六屏。只读审计（2026-11-20）确认其余页面仍在旧词汇上：13 个文件零使用新组件，系统默认灰胶囊与未加 tint 的系统蓝主按钮随处可见，卡片容器出现第二套实现。

## 共享组件升级（103-E）

- `WorkspaceView.swift` 的 `WorkspaceHeading`：body 改用与 `WorkspacePageHeading` 相同的字号/eyebrow 规格（API 不变）。
- `WorkspaceReadingViews.swift` 的 `WorkspaceSection`：body 改用 `WorkspaceCard` + `WorkspaceSectionHeading`（API 不变），消除第二套卡片实现。
- 目的：不改调用点即让 TaskInitiation、WeeklyReview、EnglishPractice、Feynman、QuestionAnswer 等页升级到同一视觉。

## 单元与文件所有权

| 单元 | 文件 | 重点 |
| --- | --- | --- |
| 103-A 启动 | `TaskInitiationView.swift` | 7 处裸按钮补层级、5 处旧 tint 主按钮换 workspacePrimary、statusChip 换 WorkspaceBadge、页头换 WorkspacePageHeading |
| 103-B 每周回顾 | `WeeklyReviewView.swift` | 完成/不再跟进改 secondaryCompact、放弃改 destructive、9 个旧区块迁移、行尾状态换徽标、页头带 trailing |
| 103-C 执行/讨论/核查 | `AssistantExecutionView.swift`、`DiscussionView.swift`、`KnowledgeReviewView.swift` | 关联成果设为主操作、发送本轮文字设为主操作、三连灰按钮分层、编辑器走 editorSurface、知识核查卡片改 WorkspaceCard |
| 103-D 弹窗与表单 | `EnglishPracticeView.swift`、`FeynmanPractice.swift`、`FullRecordingView.swift`、`TextCaptureView.swift`、`QuestionViews.swift`、`QuestionAnswerSection.swift`、`SelectionActions.swift`、`ReminderSettingsView.swift` | 消灭系统蓝主按钮、保存状态设为主操作、预设行加组标题、时间戳格式化、浮条与 Toast 语言对齐、子弹窗页头统一 |

## 硬约束

- 行为、identifier、键盘不变；不新增颜色字号；不改 data 层。
- 单文件所有权；每单元 worktree 分支 `work/m103-<unit>`，写 `work/tasks/20261120-m103-<unit>/TASK.md`，代码 + 记录两次提交。
- 唯一构建锁；真实退出码；不写实时库；不重启；不 push。