# 波 104-D：澄清队列、提醒排期与主题回访卡片视觉统一

## 背景

澄清队列、提醒排期视图与主题回访卡片仍用系统 `.borderedProminent` 蓝色主按钮、无样式裸按钮与手写圆角卡片，和波 102 起的 Workspace 组件体系不一致。本波只改 `ActionClarifyQueueView.swift`、`ReminderScheduleViews.swift`、`TopicResurfacingCard.swift`，行为、identifier、键盘与文案不变。

## 改动（行号为改前行号）

- `ActionClarifyQueueView.swift`
  - L67 关闭 → `workspaceQuiet`，dismiss 行为不变。
  - L70 剩余数量 → `WorkspaceBadge`，文字逐字保留「剩余 N 条」。
  - L69-95 当前条目块整体包进 `WorkspaceCard(padding: 16)`；标题、未归类提示、出口按钮与错误行原样搬入。
  - L75-77 归类三按钮（归为问题 / 归为目标 / 是旁白）→ `workspaceSecondary`，三者平级，不设 primary。
  - L85 配置文本模型… → `workspaceSecondary`。
  - L108-113 让 VoiceOS 试答 `.borderedProminent`（系统蓝）→ `workspacePrimary`；想清楚了、以后再说 → `workspaceSecondary`；跳过 → `workspaceQuiet`。
  - L119-122 留作目标 → `workspacePrimary`；将来也许 → `workspaceSecondary`；不是我要做的事 → `workspaceDestructive`；跳过 → `workspaceQuiet`。
  - L129 加下一步 → `workspaceSecondary`。
  - L97 空态「完成」→ `workspacePrimary`；与它同屏的页头关闭为 quiet，同区保持唯一 primary。
- `ReminderScheduleViews.swift`
  - L68 取消 → `workspaceSecondary`。
  - L82 保存本地期限 → `workspacePrimary`，`.keyboardShortcut(.defaultAction)` 保留。
  - L100-101 上次回读期限 / 拟改为 → `WorkspaceBadge`；未能核对用 warning，其余 neutral；文字逐字保留（含「：」）。
  - L111 暂不修改 → `workspaceSecondary`。
  - L120 确认并执行这一次改期 → `workspacePrimary`，默认动作快捷键保留。
- `TopicResurfacingCard.swift`
  - L13-31 自写底色与 padding → `WorkspaceCard(padding: 12)`。
  - L15「可以再看一眼」Label → `WorkspaceBadge(tone: .accent)`。
  - L20 接着探索 `.borderedProminent` + tint → `workspacePrimary`；稍后菜单原样保留。
  - 删除已无引用的 `workspacePalette` 环境值。

## 验证

- `swift build -j 2`（共享锁）：build_exit=0。
- `swift test -j 2`（共享锁）：test_exit=0，Executed 662 tests, with 0 failures (0 unexpected) in 45.775 seconds。
- 日志在 /tmp/m104-d-build.log 与 /tmp/m104-d-test.log。共享锁一次即拿到，未出现 LOCK_TIMEOUT。
- `git status` 确认只改上述三个源码文件，另加本记录。

## 取舍与风险

- 澄清队列是「一次一条」流程，没有逐行列表；唯一的容器是当前条目块，按其语义包成 `WorkspaceCard`。
- 归类三按钮原本就是平级选项，保持全体 secondary，不人为制造 primary。
- `ReminderScheduleViews.swift` 内没有删除排期的入口，destructive 映射没有落点，未新增按钮（文案与行为不变的约束）。
- 同屏 primary 唯一性：空态「完成」为 primary 时页头关闭为 quiet；问题与目标出口各自只有一个 primary。
- `TopicResurfacingCard` 从自写 accent 底色改为共享卡片后失去淡色底，状态语义由 accent badge 承载。
- 三个视图没有 UI 快照测试；行为 pin 依赖构建、662 项既有测试与文案逐字比对，真机视觉效果仍需人工确认。