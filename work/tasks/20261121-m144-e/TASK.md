# 144-E 主题阅读过滤/焦点与原文折叠保留（WorkspaceTopicReadingView / WorkspaceSourceView）

## 背景
保留一路只读发现四条：主题阅读在小主题被选中时输入过滤词会显示「没有匹配的小主题」而计数又说有匹配；主题卡片更正弹层关闭后卡片列表键盘焦点丢失；问题列表行内装饰图标未从无障碍树隐藏；保存原文更正会强制收起用户正在读的「原文与回听」折叠。目标全部最小修复。

## 文件清单（只允许动这两个）
- Sources/VoiceOSApp/WorkspaceTopicReadingView.swift
- Sources/VoiceOSApp/WorkspaceSourceView.swift

## 逐条

### 1. 过滤词优先于选中（WorkspaceTopicReadingView）
- `displayedSections`（约 56-59 行）：当前只要有 selectedSection 就与过滤结果求交集，过滤词不匹配选中项时列表为空、但计数按 filteredSections 计算。改为：
```swift
private var displayedSections: [TopicReadingSection] {
    if let selectedSection, filterTerm.isEmpty { return filteredSections.filter { $0.id == selectedSection } }
    return filteredSections
}
```
- 注意检查键盘序（handleReadingCardKey 用的 ids 来源）与 `.id(section.id)` 是否仍一致；若键盘 ids 也来自 displayedSections 则自动一致。

### 2. 更正弹层关闭后恢复卡片列表焦点
- `.sheet(item:$correctingClaim)`（约 146 行）后加 `.onChange(of: correctingClaim?.id) { _, id in if id == nil { requestCardListFocus() } }`（`requestCardListFocus()` 已存在，约 596 行）。

### 3. 装饰图标从无障碍树隐藏
- 约 396-397 行问题行内两处 Image（`questionmark.bubble`、`arrow.up.right`）位于带文字的 Button 标签内，均为装饰：分别 `.accessibilityHidden(true)`。同文件其它「图标+文字」行内装饰图标若有同样问题一并处理（grep Image(systemName 在按钮标签内）。

### 4. 保存更正不再收起「原文与回听」
- WorkspaceSourceView.swift 约 1152 行 `.onChange(of:source.transcript)` 里的 `folds.original=SourceFoldState.initial(transcript:source.transcript).original` 删除（`initial()` 忽略参数、只会把折叠复位为收起）。保留 `clearSelection();resetBilingual()`。这样转写刷新后折叠保持用户当前展开状态，已保存的滚动锚点仍在折叠内有效。

## 约束
- 不改业务逻辑与文案；不改清单外文件。
- 不跑 swift build/test（波次批处理）；改动文件跑 `xcrun --sdk macosx swiftc -parse <files>`，真实退出码。
- 完成后在本工作树提交（不推送），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。
- 每条先 grep 核实现状；机制不符的跳过并记录证据。

## 回报
提交哈希、逐条完成/跳过及原因、parse 退出码、diff --stat。