# 波 116-A 等宽数字覆盖审计与修复

基线 `work/m116-a`，工作树 `.worktrees/m116-a`。只改五个文件：`WorkspaceDesign.swift`、`WorkspaceReadingViews.swift`、`WorkspaceSourceView.swift`、`TaskInitiationView.swift`、`WeeklyReviewView.swift`。行号除注明外为改后位置。

## 目标

`Text.monospacedDigit()` 只是 Text 级字体变体，`vosFont` 内部 `content.font(...)` 会整体替换字体。先 `monospacedDigit()` 后 `vosFont(...)` 的写法等宽实际失效。逐处审计五文件，失效处改走 `vosFont` 的 `monospacedDigit:` 参数；同时只读核对全库其余调用点，只记录不改。

## 覆盖机制（判定依据）

`WorkspaceTextScale.swift:45-55`：`VOSFontModifier.body` 计算 `font` 后执行 `content.font(digits ? font.monospacedDigit() : font)`。`content` 已带先置的 Text 字体变体时，后置 `.font(...)` 会整体替换该字体，先置的 `.monospacedDigit()` 不生效。

判定规则：同一修饰链上 `.vosFont(...)` 位于 `.monospacedDigit()` 之后（下游）即失效；`.monospacedDigit()` 位于 `vosFont` 之后则生效。按钮样式 `WorkspaceButtonBody` 对 `configuration.label` 施加自己的 `vosFont`（`WorkspaceDesign.swift:464`），label 内部的 Text 级变体同样被覆盖。

## 逐处审计（五文件全部命中）

`Sources/VoiceOSApp/WorkspaceDesign.swift`

- `WorkspaceBadge`（原 `:527`，改后 `:529`）：`Text(text).monospacedDigit().vosFont(caption.size, weight: .semibold)`，vosFont 在下游，失效。改为 `vosFont(WorkspaceText.caption.size, weight: .semibold, monospacedDigit: true)`。
- `WorkspaceSectionHeading` 计数（原 `:613`，改后 `:614`）：`Text(count).monospacedDigit().vosFont(WorkspaceText.meta)`，失效。改为 `vosFont(WorkspaceText.meta, monospacedDigit: true)`。115-C 记录已标注此疑似失效并留给后续波次，本波处理。
- `WorkspaceButtonStyle`：新增 `:444` `var monospacedDigit = false`，`:447` 转传给 body，`:457` body 字段，`:464` 传入自身 `vosFont`。默认 false，其余按钮渲染不变。

`Sources/VoiceOSApp/WorkspaceReadingViews.swift`

- `:160`、`:192` 区块与列表计数：已是 `vosFont(WorkspaceText.meta.size, weight: WorkspaceText.meta.weight, monospacedDigit: true)`，等宽生效，保留。

`Sources/VoiceOSApp/WorkspaceSourceView.swift`

- `:1451`、`:1454` 回听时间码与时长：已是 `vosFont(WorkspaceText.meta.size, monospacedDigit: true)`，生效，保留。

`Sources/VoiceOSApp/TaskInitiationView.swift`

- `:134` 字数「n / 4000 字」：已是 `vosFont(WorkspaceText.caption.size, monospacedDigit: true)`，生效，保留。

`Sources/VoiceOSApp/WeeklyReviewView.swift`

- `summaryStat` 标签（`:192`）：原 `Text(title + " ") + Text("\(count)").monospacedDigit()`。非链接分支（`:202`）的 `vosFont(..., monospacedDigit: true)` 已生效；链接分支经 `.buttonStyle(.workspaceQuietCompact)`，`WorkspaceButtonBody` 的 vosFont 在下游覆盖，失效。改法：标签收回单个 `Text("\(title) \(count)")`；链接分支（`:199`）改用 `WorkspaceButtonStyle(emphasis: .quiet, compact: true, monospacedDigit: true)`，经样式保留等宽数字。
- `:202` 非链接分支：已是 `vosFont(..., monospacedDigit: true)`，保留。

标识符与文案未改；行为不变，仅等宽是否真正生效。

## 五文件外只读核对（未改）

- `WorkspaceProcessingView.swift:247`：`Text(model.dictationElapsedText).monospacedDigit()`，同链无 vosFont，但祖级 `:259` 对整个 HStack 施加 `.vosFont(WorkspaceText.meta)`，等宽疑似失效。留给后续波次。
- `WorkspaceView.swift:1214`：`Text(...).monospacedDigit().vosFont(WorkspaceText.meta)`，vosFont 在下游，失效。115-A 记录当时的判断是「不动，沿用既有写法」，与本波判定相悖；按本波规则应改为 `vosFont(WorkspaceText.meta, monospacedDigit: true)`。留给后续波次。
- `TranscriptSegmentationView.swift:11`：`Text(...).monospacedDigit()`，链上与祖级均无 vosFont，默认字体下变体生效，无需改。
- `WorkspaceTextScale.swift:53`：`font.monospacedDigit()` 位于 VOSFontModifier 内部，是机制本身，正确。
- 其余 `monospacedDigit` 命中（`PausedActionBatchView`、`RecentContentHome`、`WorkspaceMonitorView`、`WorkspaceView` 其余行、`FullRecordingView`、`TextCaptureView` 等）均为 `vosFont(..., monospacedDigit: true)` 形式，已生效。

## 验证

共享锁循环，工作目录 `.worktrees/m116-a`，`swift build -j 2` 与 `swift test -j 2` 串行，只认真实退出码。

- `build_exit=0`
- `test_exit=0`
- `Executed 669 tests, with 0 failures (0 unexpected) in 43.911 (43.972) seconds`
- 测试目标只有 `VoiceOSCoreTests`，不含 SwiftUI 字体断言（`monospaced` 无命中），视觉结果无法由单测证明。
- 代码提交：`7e9029a fix(ui): 等宽数字改由 vosFont 承载，覆层声明不再失效`

## 未做与取舍

- 未做真实 UI 目测：约束是不重启应用，验证止于全量构建与测试。
- 五文件外的疑似失效点（`WorkspaceProcessingView:247`、`WorkspaceView:1214`）只记录，未改。
- WeeklyReviewView 链接分支无法从调用点恢复等宽：样式对 label 施加自己的字体，调用点任何先置字体都会被覆盖。因此给 `WorkspaceButtonStyle` 加默认 false 的参数，这是本波唯一的设计系统改动；未新增命名便捷构造，唯一调用点直接用成员初始化。
- 未 push、未合并，记录未删。