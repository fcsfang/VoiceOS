# 137-B 结果跟进路由与录音标题预填修复

基准：main `635db41`。分支 `work/m137-ui`。未改数据层，未运行 `swift build` / `swift test`，未写实时资料库，未启动应用。

## 范围

- `Sources/VoiceOSApp/OutcomeFollowupView.swift`
- `Sources/VoiceOSApp/RecordingTitleEditor.swift`
- `Sources/VoiceOSApp/WorkspaceView.swift`（仅结果跟进的调用点，传入本窗口导航闭包）

调用点改动是条目 1 的必要接线：视图拿不到窗口模型，任务允许在调用点传入当前窗口的导航上下文。

## 逐条结果

### 1. 结果面板「去行动页」串窗

**根因。** `ControlCenter.primary` 只在 `root == nil` 且尚未赋值时被设置（`VoiceOSApp.swift:960-970`）。独立资料库窗口用 `ControlCenter(root:)` 建模，永远不会成为 primary；它的 `primary` 要么指向主窗口模型，要么为 nil。旧按钮因此要么切走主窗口，要么无反应。

**修复。** `OutcomeFollowupView` 增加 `onOpenActions` 闭包，与既有的 `onRecord` / `onOpen` / `onSkip` 同形。空态按钮先调用 `onOpenActions()`，再调用 `onDone()` 关闭 sheet。调用点传 `{ go(.actions) }`，`go` 属于该窗口的 `WorkspaceView`，所以路由落在当前窗口。单窗口场景行为不变：仍进入行动页并关闭 sheet。

**方案理由。** 闭包方案与同文件既有跳转、以及 `WeeklyReviewView.openActions` 的模式一致；不需要把 `ControlCenter` 塞进一个纯展示视图，也不会再出现“当前窗口”与全局 primary 不一致的状态。

### 2. 标题编辑器预填冻结自动命名

**修复。** 初始化改为 `record.contentTitle ?? ""`。`contentTitle` 的定义就是手动标题，或转写版本匹配时的自动标题（已收紧）。派生的 `displayTitle`（如「录音 · 10月14日 20:28」）不再进入输入框，只通过 `TextField` 的 prompt 显示为「当前显示：<displayTitle>」。输入框为空时保存按钮保持禁用（原逻辑已有），回车触发的是禁用的 defaultAction，不会保存。

**方案选择。** 采用“空输入 + placeholder + 禁用保存”。理由：

- 空保存的语义在本 sheet 里没有独立价值。清除手动标题已有专门入口「恢复自动标题」，它在 `presentation?.manualTitle != nil` 时出现并调用 `renameRecording(record, title: nil)`。
- 若改成“预填 contentTitle、空文本时按钮变「恢复默认标题」”，会把两种不同的写操作压进同一个按钮，且仍需处理自动标题场景下无手动标题可清除的情况。当前方案不新增组件，也不新增状态。

### 3. 分组重命名误操作检查

**结论：不存在“有效分组成员被本编辑器改整组标题”的路径。**

- 打开入口在 `WorkspaceSourceView.swift:1016-1021`：能通过 `model.sourcePageIndex.expression(for:)` 取得表达式且 `sourceIDs.count > 1` 的记录，一律进入 `RecordingExpressionTitleEditor`，不进入 `RecordingTitleEditor`。
- `SourcePageIndex.expression(for:)` 只由 `record.recordingExpression(in: catalog)` 填充（`RecordingContext.swift:133`），该函数校验全部成员摘要与外部版本。它比 store 里单条记录的 `recordingExpression` 更严格。
- 因此本编辑器面对的是单条记录或已失效的分组状态；有效分组不会走到这里。即使走到，标题为空时保存按钮禁用，回车无法触发 `renameRecording`。

**残余边界（未修，记录）。** 分组某成员失效（如兄弟成员转写被更正）时，索引判定表达式无效，入口可能打开本编辑器；而 store 的 `renameRecording` 只看当前记录自身的 `recordingExpression`，仍可能走整组写入。这是既有数据层行为，本次修复没有引入或加重它：空标题已无法保存，非空保存是用户明确输入。若要彻底消除，需要在数据层统一校验或在本编辑器增加分组守卫，超出本次范围。

**范围外发现。** 分组标题编辑器 `RecordingExpressionTitleEditor`（`WorkspaceSourceView.swift:1690-1715`）仍以 `expression.manualTitle ?? expression.title` 预填，存在同类“保存即冻结自动标题”的模式。本次文件约束未改，建议另开单元。

## 验证

- `xcrun swiftc -parse` 逐个解析三个改动文件，退出码均为 0。
- `git diff --check` 退出码 0。
- 逐行复核 diff，覆盖上述条目。
- 按要求未构建、未运行测试、未启动应用，因此视觉与导航行为需集成构建后确认。

## 风险

- 无运行时验证：结论来自代码路径与数据契约。macOS 26 平台上 `TextField(_:text:prompt:)` 的 prompt 仅在输入为空时显示，符合预期。
- `go(.actions)` 在 sheet 仍展示时执行，随后 `onDone()` 关闭。与同文件 `onRecord` / `onOpen` 的既有顺序模式一致。
- 失效分组边界如条目 3 所述；属于既有 store 语义，不是本修复引入。
- `ControlCenter.primary` 继续服务应用菜单等主窗口入口，未删除。