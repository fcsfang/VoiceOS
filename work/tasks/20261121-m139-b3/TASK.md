# 139-B3 材料详情页回听列表键盘导航

## 背景

材料详情页有三个回听列表：原文时间片、逐字稿大纲、章节。它们都是纯 Button，播放中只有 `palette.selection` 高亮，没有键盘选择态、焦点环或方向键。目标是让三个列表在同一个阅读 ScrollView 内支持 ↑↓ 移动与 Enter 播放，行为与点击一致。左侧 sourceRail 不在本文件，未纳入。

## 实现

- 父级 `WorkspaceSourceView` 新增一个 `@State playbackSelection:String?`，三个列表共享同一选择 id。播放 id 继续由既有 `SourcePlaybackClock` 派生，不另存一份状态，避免与播放器位置漂移。
- 新增私有 `SourcePlaybackKeyList<Content:View>`：`.focusable()+.focused+focusEffectDisabled()+.onKeyPress`。↑↓ 在自身 ids 内步进，Enter 调用与点击相同的 play 闭包；展开折叠后延迟 100ms 请求焦点，若第一响应者是 `NSTextView` 则不抢焦点。
- 行 id 加前缀区分列表：`span:<id>`、`outline:<section.id>`、`chapter:<ordinal>`。共享一个 selection id 时，跨列表步进从不存在的 id 开始，落到首行或末行。
- `SourceSpanPlaybackLabel` 与 `SourceTimedPlaybackLabel` 增加 `highlighted` 参数并纳入 Equatable；背景为 `active || highlighted ? palette.selection : hovered ? palette.hover : .clear`，播放中高亮保留。
- 行 Button 增加 `.workspaceFocusRing(highlighted && !active, radius: WorkspaceMetrics.controlRadius)`。播放中的行不叠加焦点环，selection 高亮优先。
- 步进 helper 以 `stepSourcePlaybackSelection` 复制进本文件，注释注明与 `WorkspaceKeySelection.step` 重复、后续可共享。
- 空态：原文时间片改为 `if !timedSpans.isEmpty` 才渲染列表；大纲与章节原本已有 `!isEmpty` 门控。加载失败的重试行不在列表内，不受影响。
- 无障碍标签保持原文案不变。

## 文件

- `Sources/VoiceOSApp/WorkspaceSourceView.swift`（唯一改动）

## 验证

- 按任务约束未运行 `swift build` / `swift test`。
- `xcrun swiftc -parse Sources/VoiceOSApp/WorkspaceSourceView.swift` 退出码 0。
- 人工核对：三个列表都传入 `$playbackSelection`；所有行标签调用都带 `highlighted`；无其它调用方受影响。

## 风险

- 未做类型检查与真机验证，`.focusable()` 容器嵌在 LazyVStack 内的焦点行为需实机确认。
- 多个折叠同时展开时，后出现的列表会取得焦点。这是既有列表模式的延伸，但未实测。
- 焦点环在播放行上被抑制；若希望两者同时可见，需要调整优先级。

## 后续验证

打开音频材料详情，展开「原文与回听」「逐字稿大纲」「章节」：↑↓ 移动高亮、Enter 播放对应段/章；播放中行保持 selection 高亮；空或加载失败时不出现键盘容器。