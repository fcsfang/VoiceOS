# 142-C 材料阅读的滚动跟随、慢加载门控与只读 sheet Esc（WorkspaceSourceView / IncrementalReadingView / DiscussionHistoryView / ReflectionQuestionsView）

## 背景
只读发现（交互 + 状态两路）确认：材料回听三个列表方向键选中不滚动到可见、三处本地读取占位无慢加载门控、建立主题 sheet 的「完成」只挂默认键不响应 Esc。目标全部沿用仓库既有模式最小修复。

## 文件清单（只允许动这四个文件）
- Sources/VoiceOSApp/WorkspaceSourceView.swift
- Sources/VoiceOSApp/IncrementalReadingView.swift
- Sources/VoiceOSApp/DiscussionHistoryView.swift
- Sources/VoiceOSApp/ReflectionQuestionsView.swift

## 逐条

### 1. 回听列表方向键选中滚动到可见
- `SourcePlaybackKeyList`（WorkspaceSourceView.swift，约 1380-1460 行区域，139 波新增）目前只用 selection 高亮。给每条可选中行加稳定 `.id(...)`（沿用行自身标识，如时间片 index/id、大纲 token id、章节 id），列表容器包 `ScrollViewReader`，在选中 id 变化时 `proxy.scrollTo(id, anchor: .center)`（用 `.onChange(of: selection)`，与 WorkspaceView 887/897 等的做法一致，动画尊重 reduceMotion）。
- 三个列表（原文时间片/大纲/章节）都要生效；空列表不渲染容器的现状保持不变。

### 2. 三处本地读取占位加 150ms 门控
- IncrementalReadingView.swift:27-28、DiscussionHistoryView.swift:25-26、WorkspaceSourceView.swift:379（「正在读取原文版本…」）：各加本地 `@State showSlowLoad=false`，容器挂 `.workspaceSlowLoading(isLoading, into: $showSlowLoad)`，占位只在 showSlowLoad 为真时渲染。其它行为不变。

### 3. 建立主题 sheet 的 Esc
- ReflectionQuestionsView.swift:314 附近「这个主题的资料」sheet 的「完成」按钮当前 `.keyboardShortcut(.defaultAction)`，改为 `.keyboardShortcut(.cancelAction)`（纯阅读 sheet 的关闭语义，与 140-B 五处只读 sheet 一致；一个按钮只挂一个快捷键）。

## 约束
- 不改业务逻辑、文案、数据层；不改其它文件。
- 不跑 swift build/test（波次批处理）。改动文件跑 `xcrun --sdk macosx swiftc -parse <files>`，以真实退出码为准（不经管道）。
- 完成后在本工作树提交，尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`；不推送。

## 验证
- `swiftc -parse` 退出码 0。
- `git diff --stat` 只触及清单内文件。
- 回报：提交哈希、逐条完成情况、scrollTo 使用的行 id 来源、任何判定不成立的条目及证据。