# 波 110：ui-ux-pro-max 规则对照修复

## 背景

按技能 SwiftUI 规则只读审计：图标按钮无障碍名 0 条；18 处动画未做 reduceMotion 门控；5 处系统语义色；6 处固定宽度包裹可变长文本（特大字号残留）。

## 单元

| 单元 | 文件 | 内容 |
| --- | --- | --- |
| 110-A | RecentContentHome、ReflectionGraphView、AssistantExecutionView、MarkdownText | 动画门控 + 侧列/节点/序号宽度随字号 |
| 110-B | WeeklyReviewView、WorkspaceDiscussionView、TaskInitiationView、WorkspaceReadingViews | 动画门控 |
| 110-C | WorkspaceView、VoiceOSApp、QuickNote、ReflectionQuestionsView、ReflectionChangeView | 动画门控 + 语义色 + 列宽随字号 |

## 修法

- 动画：`@Environment(\.accessibilityReduceMotion)`，`withAnimation(reduceMotion ? nil : ...)`，`.animation(reduceMotion ? nil : ..., value:)`。
- 颜色：palette.success / palette.warning / palette.danger，经 workspacePalette 环境或用例内已有 palette。
- 宽度：`N * vosLayoutScale(textScale)` 或 minWidth，保持默认字号不变。

## 约束

行为/文案/identifier 不变；唯一构建锁；真实退出码；worktree 分支合并；不写实时库、不重启。
