# 波 55 任务书（2026-11-17，用户提出）

## 需求（用户原话）

「现在首页侧边栏最近想法现在全部被最近想法占满了，我需要下滑好久才能看到其他的。这个样式，这是什么产品逻辑？现在分了最近想法，还有今天，还有昨天，按日期排序，这是什么情况？」

## 背景

`RecentContentHome.swift:506` 的 `recentThoughtsSection` 把 `RecentContentIndex.recentThoughts(days:)`（14 天窗口，`RecentContent.swift:248`）全量平铺：每天一个小标题（今天/昨天/日期 · N 条），下面列当天全部想法，无折叠、无条数上限。首页因此被挤占。

## 完成判据

1. 默认折叠：首页「最近想法」区块只显示最新 5 条（跨天按时间序），每条一行，右侧或副行标注日期（今天/昨天/x月x日）与材料名。
2. 区块标题行显示总数：「最近想法 · 14 天内 N 条」，并提供「展开全部 / 收起」切换（@State，默认收起）。展开后恢复按天分组的完整视图（现有今天/昨天/日期分组逻辑保留在展开态）。
3. N ≤ 5 时不显示切换控件，直接平铺（保留分组也可，但不得比折叠态多占空间）。
4. 点击条目打开原话的既有行为与失败提示保持不变；空态不变；accessibilityIdentifier（home.recentThoughts / recent.thought）保持。
5. 纯逻辑（截断条数、标题计数文案）抽成可测函数并加单测；渲染层只做绑定。
6. `swift build -j 2` / `swift test -j 2` 真实退出码 0。

## 文件所有权

- 单单元 HM：`Sources/VoiceOSApp/RecentContentHome.swift`、`Sources/VoiceOSCore/RecentContent.swift`（仅新增纯函数）、对应测试。
- 不碰 TaskInitiation*、VoiceOSApp.swift、处理页、主题组织。
