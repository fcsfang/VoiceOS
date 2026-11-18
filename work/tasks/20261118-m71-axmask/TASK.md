# 波 71 任务书（2026-11-18）：修容器标识掩蔽，动作标识落到叶子

## 背景（实机验证 2026-11-18，波 70 安装后）

AX 实测：`nav.*` 7 个标识全部生效，按标识 AXPress `nav.monitor` 成功打开监测页。但 354 个 `monitor.*` 标识里 `monitor.item.<id>.complete`、`.dismiss`、`.reopen`、`.evidence` 一个都没有浮出；事项行内 Image、StaticText、两个按钮全部报同一个 `monitor.item.<id>`。原因：SwiftUI 把容器的 accessibilityIdentifier 传播给所有后代，行级标识将子按钮的动作标识盖住（调研报告同样记录该陷阱）。后果：agent 无法按标识点「标记完成」，只能回到中文 label。

## 完成判据

1. 事项行去掩蔽：移除行容器上的 `monitor.item.<id>` 标识（或按需改用 `.accessibilityElement(children: .contain)` 后再挂容器标识，参照「容器标识不得覆盖子元素」原则）；`标记完成`、`不适用`、`重新打开`、`原文与来源` 展开三角四个叶子控件各自保留自己的标识。
2. 全量自查同类掩蔽：对波 70 清单中所有「容器 + 子控件」组合逐一核对（至少：历史行 `monitor.history.<id>`、来源行 `monitor.source.<id>.*`、QQ 会话行 `monitor.settings.qq.conversation.<id>`、处理页各类行 `processing.*.<id>.*`）。规则：动作标识只挂在 Button/Toggle/DisclosureGroup/TextField/Picker 等叶子；纯展示容器若需锚点再加 identifier，且确认子动作仍可按自身标识寻址。
3. 不改布局、文案、行为；不加迁移；不碰 Core/Platform；不碰 `ArticleExtractor.swift`。
4. `swift build -j 2` / `swift test -j 2` 真实退出码 0（先 merge main，基线 610 项）。
5. 结果清单给出「掩蔽修复处」列表（file:line 与被移除/保留的标识），供协调方安装后 AX dump 复核（复核命令：按 `monitor.item.<id>.complete` 应能命中 AXButton）。

## 文件所有权

- `Sources/VoiceOSApp/WorkspaceMonitorView.swift`
- `Sources/VoiceOSApp/WorkspaceProcessingView.swift`
- `Sources/VoiceOSApp/WorkspaceView.swift`
- 不碰其他文件。

## 约束

- 16GB：构建/测试共用 `/tmp/voiceos-swift-build.lock`（mkdir 抢锁、陈旧锁按 mtime 2400 秒回收、结束 rmdir）；先 merge main。
- 不写实时库；不重启应用；不 push、不合并、不重建 dist。
- 分支 `work/m71-axmask`，提交回报。

## 结果（2026-11-18）

分支 `work/m71-axmask`，基于 main `e95ca3f`（合并时已是最新，无新 main 提交）。代码提交 `cb093c3`。本结果所在提交为第二个 docs 提交。

### 根因

SwiftUI 把容器视图上的 `accessibilityIdentifier` 传播给全部后代。事项行容器 `VStack` 在原 323 行挂了 `.accessibilityIdentifier("monitor.item." + item.id)`。行内 Image、StaticText、两个按钮与证据展开三角都报行标识，叶子动作标识被盖住。

### 掩蔽修复处

- `Sources/VoiceOSApp/WorkspaceMonitorView.swift` 原 323 行：移除行容器标识 `monitor.item.<item.id>`。
- 没有改用 `.accessibilityElement(children: .contain)` 保留锚点。仓库内没有脚本或文档按裸行标识寻址，删除是最小改动，也不新增 VoiceOver 分组行为。
- 保留的四个叶子标识（当前行号）：
  - 305 `monitor.item.<item.id>.complete`，Button「标记完成」
  - 308 `monitor.item.<item.id>.dismiss`，Button「不适用」
  - 312 `monitor.item.<item.id>.reopen`，Button「重新打开」
  - 365 `monitor.item.<item.id>.evidence`，DisclosureGroup「原文与来源」

### 全量自查

对波 70 清单中的标识逐一核对。三个文件当前只有上述一处容器标识，其余都挂在叶子控件：

- `WorkspaceMonitorView.swift`：`monitor.page`（Picker）、`monitor.runCheck`（Button）、`monitor.history.<id>`（WorkspaceRow，completion 为 nil 时渲染 Button）、`monitor.report.*`（Button）、`monitor.filter`（Picker）、`monitor.sources.*`（Button）、`monitor.source.<id>.enabled`（Toggle）、`.delete`（Button）、`.start`（DatePicker）、`monitor.settings.*`（DatePicker、Toggle、Picker、SecureField、Button）、`monitor.settings.qq.conversation.<id>`（Button）。
- `WorkspaceProcessingView.swift`：全部 39 处都是 Button。
- `WorkspaceView.swift`：`workspace.savedView.<name>`（Button）、`nav.settings`（Button）、`nav.<id>`（Button）、`workspace.discussion`（WorkspaceIconButton，内部是 Button）。

复核命令：`rg -n 'accessibilityIdentifier' Sources/VoiceOSApp/WorkspaceMonitorView.swift Sources/VoiceOSApp/WorkspaceProcessingView.swift Sources/VoiceOSApp/WorkspaceView.swift`。

### 范围外发现（未改）

- `Sources/VoiceOSApp/RecentContentHome.swift:540` 的 `home.recentThoughts` 挂在容器 VStack 上，盖住 534 行 Button 的 `recent.thought`，属同类掩蔽。该文件不在本波所有权内，未改。
- 同文件 434 `home.thread`、493 `home.tasks.list`、572 `home.organizePrompt` 也是容器标识。子树上没有其他标识，只造成寻址噪声，不掩蔽动作标识。
- 其余文件（`WorkspaceTheme.swift`、`WorkspaceReadingViews.swift`、`TaskInitiationView.swift`、`VoiceOSApp.swift`）的标识都挂在 Button、Toggle、Picker、TextEditor、Text 等叶子上。

### 判据落点

- 判据 1：行容器标识已移除，四个叶子控件保留自身标识。安装后按 `monitor.item.<id>.complete` 应命中 AXButton。
- 判据 2：自查清单见上。三文件内没有其他容器掩蔽，范围外同类问题已列出。
- 判据 3：只删一行属性。未改布局、文案、行为，未加迁移，未触碰 Core、Platform 与 `ArticleExtractor.swift`。
- 判据 4：构建前执行 `git merge main --no-edit`（已是最新）。`swift build -j 2` 退出码 0（107.90 秒）。`swift test -j 2` 退出码 0，610 项测试，0 失败，与基线一致。构建与测试共用 `/tmp/voiceos-swift-build.lock`，结束后已释放。
- 判据 5：修复处与保留标识见上。

### 原则与选择

- Laziness Protocol：删除一行属性解除掩蔽，没有引入 `.contain` 分组或新抽象。
- Fix Root Causes：修容器标识本身，不给子按钮补叶子上游的工作区。
- Prove It Works：以 build/test 真实退出码与 610 项测试为证据。AX 实机复核留给协调方安装后执行，本波不重启应用。

### 遗留风险

- 本波不能在本机做 AX dump（不重启应用）。修复依据是 SwiftUI 传播机制与波 70 实机证据，最终以协调方安装后的 AX dump 为准。
- 分段控件只能给容器挂标识，`monitor.page` 与 `monitor.filter` 的分段仍按中文标题寻址，改标题会断（沿用波 70 遗留）。
- 动态标识依赖数据层 ID，ID 变化时标识随之变化（沿用波 70 遗留）。
