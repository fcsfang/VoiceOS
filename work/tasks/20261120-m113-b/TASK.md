# 波 113-B 工作区页级错误的单一入口

基线 `work/m113-b`，工作树 `.worktrees/m113-b`。只改 `Sources/VoiceOSApp/WorkspaceView.swift`。

## 目标

页底错误原本是一行纯红字，无关闭、无重试，且可能与顶部 `workspaceErrorBanner` 显示同一条错误。本轮把页底升级为 `WorkspaceNoticeText(.danger)` 加关闭，只在确有重试闭包时给「重试」；库级错误继续由 banner 承担；同一文案不上下重复。

## 错误分类清单

### 可重试（有真实闭包，页底给「重试」）

| 赋值点 | 失败文案 | 重试闭包 |
| --- | --- | --- |
| 状态更新失败（`:2215-2220`） | `状态未能更新，请稍后重试。` 或 `model.status` | `applyActionState(action,to:state,nextHighlight:)` |
| 撤销状态变更失败（`:2253`） | `未能撤销，请稍后重试。` 或 `model.status` | `undoActionChange()` |
| 批量更新失败（`:2508-2523`） | `有 N 条行动未能更新，请稍后重试。` | 按捕获的失败记录重跑 `applyActionBatch(state,records:)` |
| 视图保存失败（`:2678`） | `视图未能保存，请稍后重试。` | `Task { await saveView() }` |
| 视图删除失败（`:2683`） | `视图未能删除，请稍后重试。` | `deleteSavedView(view)` |

### 不可重试（写明下一步，保持原文案，不给按钮）

- 保存互斥：`正在保存其他更改，请稍后重试`（`:1422`）。
- 外部完成候选变化：`提醒事项关联或最新回读已变化，请查看最新状态`（`:2197`）。
- 链接与条目失效：`链接缺少条目身份`、`这个主题已不在当前资料库` 等（`:2715-2722`）。
- 讨论选中项提示：`先选中一条材料，再开始讨论。`、`这个页面没有可讨论的选中项…`（`:2839-2864`）。
- 资料库前置条件：`资料库尚未打开`（`:2255`）。banner 的重试类型只有本地语音、文本模型、导出、刷新四类，且 `reportWorkspaceError` 是模型私有方法，视图层无法合成诚实的 banner 重试，因此留在页底。
- `.localizedDescription` 的原始原因（如 `:431`、`:1425`、`:2030`、`:2043`、`:2661`）不套 `InlineFailurePresentation`，避免改动承诺语义；原按钮或菜单可再次触发。
- 子视图 `WorkspaceTopicEntry` 自带就近错误位（`:2880+`），已满足「就近显示」，未动。

### 库级（走 banner）

- 本文件没有直接写 `workspaceLastError` 的赋值点。banner 只由 `ControlCenter.reportWorkspaceError` 的四类路径产生：本地语音、文本模型、导出、刷新。
- 去重规则：页底文案与 `model.workspaceLastError` 完全相等时不渲染页底（`:584`），同一条错误只出现一处。

## 逐条修法

1. 页底错误行改为 `WorkspaceNoticeText(message:error,severity:.danger)`，右侧「重试」只在 `errorRetry` 的消息仍是当前错误时出现，关闭按钮清空 `error` 与 `errorRetry`（`:584-591`）。关闭按钮沿用 banner 的 `xmark` 与 `accessibilityLabel("关闭错误提示")`。
2. 新增 `errorRetry: (message: String, action: () -> Void)?`（`:342`）与 `fail(_:retry:)`（`:2206-2209`）。闭包与消息配对存储，旧闭包不会落到新错误下面；既有直接 `error =` 的赋值仍可用，清空后无可点按钮。
3. 四个点名赋值点接线：状态更新（`:2215-2220`）、撤销（`:2253`）、批量更新（`:2508-2523`）、视图保存（`:2678`）；同一模式的视图删除（`:2683`）一并接线。
4. 文案核对：四处原固定文案都是「操作 + 下一步」，没有纯「失败」或语法不通，未改。`InlineFailurePresentation` 是「操作失败：原因」口径，本轮只核对，不重写已有文案。
5. 未改 accessibility identifier，未动视觉系统其他部分。

## 验证

共享锁循环，工作目录 `.worktrees/m113-b`。

- 基线：`baseline_build_exit=0`、`baseline_test_exit=0`、`Executed 669 tests, with 0 failures (0 unexpected) in 46.102 (46.161) seconds`
- 改动后：`build_exit=0`、`test_exit=0`
- `Executed 669 tests, with 0 failures (0 unexpected) in 44.723 (44.783) seconds`

## 未做与取舍

- 未做真实 UI 驱动：本轮约束是不重启应用，验证止于全量构建与测试。
- 其余「可在原控件重试」的失败未接页底闭包：`toggleFocus`、`openReminderSettings`、`completeLocally`、`setMaterialReading`、`completeOutcome`、讨论入口等。它们仍可重复原操作，页底不显示假按钮；后续可按同样模式逐点接。
- 批量重试按失败记录重放；重试期间若行动被其他窗口改动，`changeAction` 的版本校验会再次判失败并保留错误，不会覆盖他人改动。
- 去重条件是文案完全相等；模型层给出同义不同文案时仍可能上下各一条。
- 未 push、未合并。