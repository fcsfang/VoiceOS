# 波 117-A 三处列表行的 VoiceOver 朗读顺序

基线 `work/m117-a`（基于 main c8fb253），工作树 `.worktrees/m117-a`。只改 `Sources/VoiceOSApp/RecentContentHome.swift`、`WorkspaceTopicReadingView.swift`、`WorkspaceMonitorView.swift`。

## 目标

三处列表行在 VoiceOver 下把图标名读进标题，状态只靠颜色和图形表达。改成行级显式 label，图标与装饰性箭头隐藏，状态文字进入朗读内容，检查结束补一条一次性播报。

## 逐条修法

### 1. 主列表行（`RecentContentHome.swift`）

- `:256-257` 行容器加 `.accessibilityElement(children: .ignore)` 与显式 `.accessibilityLabel(...)`；`:261` 起为拼接 helper。
- 拼接顺序固定为标题、状态、时间、徽标；空项跳过。状态取 `rowStatusNote`，时间取 `timeLabel`，徽标取 `rowTrailing` 的文本（徽标与纯文本两种分支都取文案）。
- 行首图标原有 `.accessibilityHidden(true)` 保留。可见文案、`recent.item` 标识与徽标视觉未改。
- 示例：
  - `周会纪要，疑点 2，14:30，3 条待办`
  - `访谈录音，在读，09:12`
  - `无状态材料，18:40`（无状态、无徽标时只剩标题与时间）

### 2. 主题阅读行动行（`WorkspaceTopicReadingView.swift`）

- `:476-477` 状态图标、`:482-483` chevron 加 `.accessibilityHidden(true)`；`:488` 行级 label；`:492` 起为拼接 helper。
- 状态图标承载三种语义，label 里显式写出：`completed` 为「已完成」，`kind == task` 为「待办」，其余为「想法」。后面再接可见状态行（`workspaceExternalCompletionNote` 优先，否则 `workspaceActionStatus`）。
- 示例：
  - `提交报名表，待办，尚未登记完成`
  - `整理访谈提纲，已完成，已登记完成`
  - `给导师发邮件，想法，问题与目标 · 不计为已承诺待办`

### 3. 监测事项与 QQ 诊断（`WorkspaceMonitorView.swift`）

- `:560` 状态图标加 `.accessibilityHidden(true)`；`:570-571` 行级 label；`:626` 起为拼接 helper。label 为「已完成/已忽略/待办」+ 标题 + 截止时间。
- 示例：
  - `待办，交实验报告，截止 11月25日`
  - `已完成，交实验报告，明天`
  - `已忽略，缴费提醒，截止待核对`
- `:1062-1068` QQ 诊断图标隐藏并补行级 label。核对结论：成功项的 `detail` 只是路径或版本号，不写“可用/通过”，失败项才带原因，所以成败必须进 label。示例：`通过，Python 解释器，/usr/bin/python3`、`需要处理，读取脚本，脚本缺失：…`。

### 4. 检查完成播报

- `:100-103` 监听 `model.monitorChecking`，只在 true 变 false 时调用一次播报。不监听 `monitorStatus` 文本，避免检查期间每秒刷新重复播报。先例为 `WorkspaceDesign.swift:216`。
- `:161-178` 播报内容按报告终态区分：`complete` 播「检查完成，N 项待办」或「检查完成，没有待办」；`incomplete` 播「检查结束，不完整，…」；`failed` 播「检查未完成」；最新报告缺失时播「检查结束」。条数取 `monitorOpenItemCount`，检查结束前事项已 `forceItems` 重载，值可得。
- 自动检查与手动检查都会触发，但只有监测页在视图层级中时才会播报。

## 验证

共享锁循环，工作目录 `.worktrees/m117-a`，`swift build -j 2` 与 `swift test -j 2` 串行，只认真实退出码。

- `build_exit=0`
- `test_exit=0`
- `Executed 669 tests, with 0 failures (0 unexpected) in 46.320 (46.387) seconds`（与 116-C 同为 669，无测试增减）
- 代码提交 `9a55198 fix(a11y): 三处列表行改用显式朗读标签，监测检查结束时播报`

## 未做与取舍

- 未重启应用，未做 VoiceOver 实机朗读验证；验证止于全量构建与测试。朗读顺序依赖 SwiftUI accessibility 运行时，本波禁止重启应用，无法在实机确认。
- 主列表行的来源域名未单独朗读，以保持任务指定的「标题，状态，时间，徽标」四段顺序。
- 未新增单元测试：三处都是 SwiftUI 视图 label，仓库没有视图级 accessibility 断言入口，新增测试成本高于改动本身。
- 检查播报只在监测页可见时触发；页面不在层级中时检查结束不播报。