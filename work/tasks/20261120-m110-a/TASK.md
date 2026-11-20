# 波 110-A：动画门控与宽度随字号

## 背景

按 ui-ux-pro-max SwiftUI 规则修复波 110 审计项：三处动画未做 reduceMotion 门控、四处固定宽度包裹可变长文本。行为、文案、accessibilityIdentifier 不变。仅改 RecentContentHome、ReflectionGraphView、AssistantExecutionView、MarkdownText 四个文件。

## 改动（file:line，改后行号）

| 文件 | 位置 | 改动 |
| --- | --- | --- |
| Sources/VoiceOSApp/RecentContentHome.swift | :18 | 新增 `@Environment(\.accessibilityReduceMotion)` |
| 同上 | :480 | 跳到待办列表 `withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15))` |
| 同上 | :540 | 想法序号 `frame(width: 18)` 改为 `18 * vosLayoutScale(textScale)` |
| 同上 | :648 | 最近想法展开 `withAnimation(reduceMotion ? nil : ...)` |
| 同上 | :850 | ClueHeaderMenu 新增 reduceMotion 环境 |
| 同上 | :898 | 悬停淡入 `.animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: visible)` |
| Sources/VoiceOSApp/ReflectionGraphView.swift | :26 | 新增 `@Environment(\.accessibilityReduceMotion)` |
| 同上 | :450 | 定位滚动 `withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25))` |
| 同上 | :464 | 节点标题补 `.help(node.title)`；节点卡 196×104 属图谱布局坐标，未改尺寸 |
| Sources/VoiceOSApp/AssistantExecutionView.swift | :101 | 新增 `@Environment(\.vosTextScale)` |
| 同上 | :150 | 左侧列表 `frame(width: 250)` 改为 `250 * vosLayoutScale(textScale)` |
| Sources/VoiceOSApp/MarkdownText.swift | :57 | 有序序号 `frame(width: 22)` 改为 `frame(minWidth: 22 * vosLayoutScale(scale))` |

## 验证（真实退出码）

- 唯一构建锁 /tmp/voiceos-swift-build.lock 下运行，`swift build -j 2`：build_exit=0（日志 /tmp/m110-a-build.log）
- `swift test -j 2`：test_exit=0，`Executed 669 tests, with 0 failures (0 unexpected)`（日志 /tmp/m110-a-test.log）
- diff 范围：4 文件，12 insertions / 7 deletions，无其他改动

## 风险

- `vosLayoutScale` 上限 1.3（特大字号 1.45 只放大到 1.3），与首页时间列既有约定一致；默认字号数值完全不变。
- 图谱节点卡 196×104 按约束未改；特大字号下节点标题仍可能截断，仅以 help 提示补偿，无视觉扩展。
- MarkdownText 序号由固定宽改为 minWidth，长序号自然撑开，行首 trailing 对齐保持。
- 未在真实应用内做视觉验收（约束：不写实时库、不重启），验证限于编译与单元测试。