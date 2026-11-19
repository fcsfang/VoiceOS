# 波 107：对抗审查确认的视觉统一回归

## 背景

波 105 视觉统一后，对抗审查确认 11 处回归：材料行丢疑点、侧栏 attention 徽标挤成多行、知识核查三层卡片、按钮字型与命中区、推送横幅遮挡、标题解析碎片、无障碍标签丢计数、提醒核对按钮命名不一致、监测标识符被容器遮蔽。修法逐条如下，行号均为修复前位置。

## 逐条修法

### 1 材料行丢失「疑点 M」
- 位置：`Sources/VoiceOSApp/WorkspaceView.swift:1958-1963`
- 原因：`trailingDisplay` 在 `openCount > 0` 时只取「N 条待办」，而 `trailingText` 已含疑点。
- 修法：`trailingDisplay=trailingText`，徽标显示「N 条待办 · 疑点 M」。

### 2 / 9 侧栏 attention 行徽标换行
- 位置：`Sources/VoiceOSApp/WorkspaceView.swift:253-271`
- 原因：130pt 侧栏里两个 `WorkspaceBadge` 与文本挤在一行，胶囊折成多行。
- 修法：去掉两个徽标，改为一个 `Circle` 圆点加一个可换行的 `Text`，内容「需要查看 · 转写疑点 N · 其他 M」；删除不再使用的 `attentionTitle`；`accessibilityLabel` 使用同一可见文案加「打开处理情况」，包含「需要查看」。按钮、help 与跳转不变。

### 3 知识核查三层卡片
- 位置：`Sources/VoiceOSApp/KnowledgeReviewView.swift:6-32`、`Sources/VoiceOSApp/WorkspaceSourceView.swift:887`
- 原因：`SourceSection` 已画 `WorkspaceCard`，`KnowledgeReviewSection` 内再画一层。
- 修法：增加 `var carded: Bool = true`。`carded` 为假时不画边框与卡片 padding，改用 `palette.accent.opacity(0.05)` 背景加 12 圆角、12 padding；资料详情调用点传 `carded:false`。

### 4「AI 归纳问题」按钮字型
- 位置：`Sources/VoiceOSApp/ThoughtPanoramaView.swift:1135`
- 原因：label 上的 `.vosFont(WorkspaceText.caption)` 覆盖了 `WorkspaceQuietCompact` 的 12.5 medium。
- 修法：删除该行，保留 `lineLimit` 与 `truncationMode`。

### 5 推送横幅按钮遮住文案
- 位置：`Sources/VoiceOSApp/WorkspaceMonitorView.swift:140-152`
- 原因：`overlay(alignment:.trailing)` 把「去设置」叠在通知文本上。
- 修法：改回 `HStack`，通知文本在左、按钮在右，窄列下文本换行不重叠；`monitor.push.banner` 与 `monitor.push.banner.settings` 保留。

### 6 标题解析碎片
- 位置：`Sources/VoiceOSCore/WorkspaceTitleFit.swift:32-38`
- 原因：直接取最后一段，`/watch`、`/s` 等路径片段成了标题。
- 修法：最后一段为空、UTF-8 字节数不超过 2、或命中保留词 `watch`/`s`/`p`/`index`/`view`/`detail` 时，标题回退 host，`source` 置 nil。host 为空的 scheme-only 输入保留原文，避免空标题。短片段按 UTF-8 字节数判断，避免把两字中文标题（如「学习」，6 字节）误判。
- 测试：新增 youtube watch、weixin `/s?__biz`、`https://www.example.com/` 空路径三条。

### 7 ReaderDisclosure 无障碍丢计数
- 位置：`Sources/VoiceOSApp/ThoughtPanoramaView.swift:1278`
- 修法：label 改为 `title + (count != nil ? "，\(count) 项" : "")`，四个调用点自动生效。

### 8 设置页提醒核对动作
- 位置：`Sources/VoiceOSApp/WorkspaceView.swift:1750-1757`
- 原因：可见文字「去核对」在按钮里，计数徽标不可点，无障碍名与可见文字不一致。
- 修法：徽标与「去核对」合成一个 `Button`，label 为 `HStack(WorkspaceBadge("N 条提醒待核对", warning), Text("去核对"))`，`accessibilityLabel` 同时含计数与「去核对」，点击行为不变。

### 10「AI 交付 N 份待读」命中区
- 位置：`Sources/VoiceOSApp/WorkspaceView.swift:1153-1157`
- 修法：`WorkspaceBadge` 外包 `frame(minHeight: WorkspaceMetrics.rowActionMinHeight)`、水平 padding 6、`contentShape(Capsule())`，徽标外观不变。

### 11 监测标识符被容器遮蔽
- 位置：`Sources/VoiceOSApp/WorkspaceMonitorView.swift:466`
- 原因：HStack 上的 `monitor.earlierOpen` 盖住叶子按钮标识符。
- 修法：删除该容器标识符，保留 `monitor.earlierOpen.loadMore` 与 `monitor.earlierOpen.expand`。已 grep 确认无其他引用。

## 构建与测试

按任务给定的共享锁门执行，真实退出码如下。

- `swift build -j 2`，`build_exit=0`
- `swift test -j 2`，`test_exit=0`
- `Executed 665 tests, with 0 failures (0 unexpected) in 41.620 (41.676) seconds`

最终树在补齐测试文件末尾换行后重跑，以上为最终树的真实结果。换行修复前同一门也得到 `build_exit=0`、`test_exit=0`、665 条 0 失败。

## 风险

- 侧栏 attention 行去掉独立徽标后，warning/neutral 的胶囊色彩信息变成圆点颜色加文字；信息量保留，视觉弱化是有意取舍。
- `carded:false` 用 tint 背景区分内层，不再画边框；与外层卡片的层级仍靠背景色与圆角区分。
- 标题回退按 UTF-8 字节数判短片段，是「长度不超过 2」的保守实现，优先保住两字中文标题。
- 裸 `https://` 这类无 host 输入保留原文，不产生空标题。
- UI 层未在真实应用重启验证（任务禁止重启），只过编译与单元测试；第 1、2、3、5、8、10、11 条为布局与无障碍改动，单元测试无法覆盖。

## 约束

不写实时库、不重启、不 push、不合并。