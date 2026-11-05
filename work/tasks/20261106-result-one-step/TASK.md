---
status: planning
started: 2026-11-06
updated: 2026-11-06
branch: -
pr: -
owner: coordinator
---
# 完成事项的一步结果入口

## 目标

41 项已完成事项没有结果。当前入口要经过行动页、只显示数量的区块、弹窗、再跳到任务页、滚动并展开折叠区才能填一句结果；冻结外部完成的条目甚至没有编辑器。把它收敛成一步。

## 现状证据

- 队列：`OutcomeFollowupStore.swift:28-43` 只保留已完成且 current 或已确认外部完成的行动；`recentActionOutcomes` 只在外部完成 revision 存在时纳入冻结行动。
- 展示：`WorkspaceView.swift:550-557` 的「完成后的结果」只显示数量与两个按钮，不列出条目；全部跳过后整个区块消失，「显示已跳过」也随之不可达。
- 弹窗：`OutcomeFollowupView.swift:28-45` 每个条目有「记录结果」，但点击只关闭弹窗并 `go(.task)`（`WorkspaceView.swift:236-237`），不会打开编辑器。
- 任务页：编辑器在 `WorkspaceActivityViews.swift:236-252` 的折叠区，只有 `current` 为真才显示（`:133`）；冻结外部完成的条目 `current` 为假，因此点过去无路可走，而队列又刻意包含它们。
- 保存：`saveFeedback` → `recordActionFeedback`（`ActionFeedback.swift:46-49`）→ `recordExpression`，版本过期会被拒绝（`UserExpression.swift:22-25`）；成功后刷新，条目移出队列。

## 选项

- A 在「完成后的结果」区块内逐行放一行输入框与保存、跳过。发现性最高，仍用现有保存路径；41 行需要惰性渲染或显示最近 N 项；「显示已跳过」必须移出空判。
- B 每个已完成行加「补结果」，打开只含结果字段的弹窗。发现性取决于行入口；逐个开关，容易形成两个结果弹窗并存。
- C 一次一项的顺序提示。负担最小但隐藏列表、强迫模式，且旧积压会先于刚完成的事项。

## 建议

选 A，最小改动：`WorkspaceView.swift` 的区块改为列出条目，行内一行输入，直接调用 `model.saveFeedback`；跳过调用现有 `model.skipOutcome`；「显示已跳过」移出空判。不改 store、不新增结果管线。冻结外部完成的条目也能保存，因为它只需要 `ActionRecord` 与版本。

## 测试计划

- 队列包含已完成 current；保存后移出；重开并再次完成产生新条目并保留旧结果历史。
- 冻结外部完成条目进入队列并能按确认版本保存；未确认的冻结完成不进入。
- 过期版本被拒绝并给出内联错误；不同文本换新 `commandID`。
- 区块在跳过全部后仍可达「显示已跳过」；41 项惰性渲染。

## 待你决定

1. 入口放在「完成后的结果」区块、每个已完成行、首页卡片，还是完成后立即提示。
2. 全部 41 项平铺、只显示最近 N 项，还是一次一项。
3. 只收一行结果，还是同时提供结果/反思切换与口述。
4. 保存时是否默认排队后台知识整理（任务页默认允许云端，弹窗有开关）。
5. 跳过是永久按版本、可重置，还是另有语义；「显示已跳过」放在哪里。
6. 冻结外部完成的条目是否必须可填结果。
7. 排序用最早创建还是最近完成。
8. 是否保留并整合 `OutcomeFollowupView` 与任务页编辑器为同一个入口。

## 非目标

- 不改结果数据模型、不新增保存管线。
- 不在锁屏状态下改界面；实机核对留到解锁后。

## 链接

`OutcomeFollowupStore.swift`、`WorkspaceView.swift`、`OutcomeFollowupView.swift`、`WorkspaceActivityViews.swift`、`ActionFeedback.swift`、`UserExpression.swift`；任务卡由只读调查产出。
