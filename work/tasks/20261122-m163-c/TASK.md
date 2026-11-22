# 163-C 英文反馈与自动入口的滚动塌陷修复（EnglishPracticeView / RecordingInbox）

## 背景（评审发现，机制明确）
两页在常见窗口高度下内容超出可用高度且页面无外层滚动：
- 英文表达反馈（156-A 卡片化后）：反馈历史卡挤占弹性高度，「可选旧练习」列表被压到 0–几 pt，历史列表只剩一行；窗口无法滚动找回。
- 自动入口（154-A 卡片化后）：「需要处理」卡内列表塌成 0，底部「手动检查」卡被裁掉，页面不可滚动。

## 文件清单（只允许动这两个）
- Sources/VoiceOSApp/EnglishPracticeView.swift
- Sources/VoiceOSApp/RecordingInbox.swift

## 改动
1. **EnglishPracticeView**：页面主体改为外层 `ScrollView`（页头与卡片在内、保持列宽与卡距）；「可选旧练习」列表给固定合理高度（如 160–200）或随内容但设最小高度（≥120）；「反馈历史」卡内列表给固定高度（如 240）内部滚动。保证 700pt 高窗口下两列表均可用、可滚动。
2. **RecordingInbox**：页面主体改为外层 `ScrollView`；「需要处理」卡内列表固定高度（如 180）内部滚动，不再弹性塌陷；「手动检查」卡始终可达。
3. 不改任何动作、状态、文案与卡组结构；嵌入/非嵌入模式行为一致（非嵌入时 sheet 高度已定，外层 ScrollView 仍生效）。

## 约束
- 只改这两个文件；不跑 swift build/test；改动文件跑 `xcrun --sdk macosx swiftc -parse`，真实退出码。
- 完成后提交（不推送；任务书一并提交），尾注 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 回报
提交哈希、两页的滚动与高度策略、parse 退出码、diff --stat。