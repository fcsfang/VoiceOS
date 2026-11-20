# 132-B 列表与区块行间分隔线统一为 WorkspaceListDivider

## 背景

应用已有统一发丝线组件 `WorkspaceListDivider`（`WorkspaceReadingViews.swift:89`，`palette.border` 1px），但各页仍混用裸 `Divider()`。系统分隔色在 canvas 底色上色调不一致，同一页会出现两种线。本波把横向行间规则统一为组件，菜单与竖向面板分隔保留系统样式。

## 改法

按行号逐处分类后由脚本 `replace_dividers.py` 机械替换。替换只把 `Divider()` 改成 `WorkspaceListDivider()`，保留原有的 `.frame`、`.padding` 等修饰，其余文字、间距与顺序不动。

替换 86 处，涉及 24 个文件：

| 文件 | 处数 |
| --- | ---: |
| WorkspaceView.swift | 9 |
| WorkspaceSourceView.swift | 9 |
| WeeklyReviewView.swift | 11 |
| ThoughtPanoramaView.swift | 8 |
| WorkspaceActivityViews.swift | 8 |
| ReflectionGraphView.swift | 5 |
| AssistantExecutionView.swift | 4 |
| TaskInitiationView.swift | 4 |
| ReflectionChangeView.swift | 3 |
| BilingualView.swift | 2 |
| CorrectionImpactView.swift | 2 |
| DiscussionHistoryView.swift | 2 |
| DiscussionView.swift | 2 |
| RecentContentHome.swift | 2 |
| ReflectionQuestionsView.swift | 2 |
| ReverifyControls.swift | 2 |
| TextCaptureView.swift | 2 |
| WorkspaceDiscussionView.swift | 2 |
| WorkspaceTopicReadingView.swift | 2 |
| ClaimReviewHistoryView.swift | 1 |
| EnglishPracticeView.swift | 1 |
| QuestionAnswerSection.swift | 1 |
| TranscriptSegmentationView.swift | 1 |
| VoiceOSApp.swift | 1 |

唯一非纯 token 替换是 `ReflectionGraphView.swift:117`。原行 `Divider().overlay(palette.text.opacity(0.12))` 整行改为 `WorkspaceListDivider()`，旧 overlay 去掉，线色改由 `palette.border` 提供。

## 保留清单

保留裸 `Divider()` 19 处。替换后裸计数与清单相等。

菜单与命令内容，10 处，保留系统菜单分隔样式：

- `RecentContentHome.swift:885`，`Menu` 内容。
- `TextCaptureView.swift:223`，`Menu("模板")` 内容。
- `ThoughtPanoramaView.swift:218`，`Menu` 内容。
- `ThoughtPanoramaView.swift:220`，`Menu` 内容。
- `VoiceOSApp.swift:4607`，`CommandGroup` 菜单命令。
- `VoiceOSApp.swift:4614`，`CommandGroup` 菜单命令。
- `WorkspaceSourceView.swift:610`，`Menu` 内容。
- `WorkspaceSourceView.swift:617`，`Menu` 内容。
- `WorkspaceSourceView.swift:625`，`Menu` 内容。
- `WorkspaceView.swift:2148`，`.contextMenu` 内容。

竖向面板分隔，8 处。`WorkspaceListDivider` 是 `frame(height: 1)` 的横向矩形，放进 `HStack` 会横向铺开并改变布局；本次不新增竖向变体，保留系统 `Divider()`：

- `AssistantExecutionView.swift:151`，左侧列表与详情两栏。
- `ReflectionChangeView.swift:42`，关联列表与对照详情两栏。
- `ReflectionGraphView.swift:134`，图谱与检查器两栏。
- `ReflectionQuestionsView.swift:88`，问题列表与详情两栏。
- `ThoughtPanoramaView.swift:50`，全景与侧读区两栏。
- `WorkspaceView.swift:419`，侧栏与主列。
- `WorkspaceView.swift:422`，主列与讨论面板。
- `WorkspaceView.swift:855`，材料栏与正文。

固定高度工具条分隔，1 处：

- `PanoramaConstellation.swift:1143`，`Divider().frame(height: 14)`，缩放工具条中按钮之间的竖向分隔，依赖系统 Divider 的竖向取向。

## 验证

- `python3 -I work/tasks/20261121-m132-dividers/replace_dividers.py` 输出 `replaced=86 keep=19 remaining_bare=19`，脚本逐行断言后对账剩余集合与保留清单完全一致。
- 替换后 `grep -rn "Divider()" Sources/VoiceOSApp` 原始命中 170 行。其中 `WorkspaceListDivider()` 151 行，裸 `Divider()` 19 行。注意普通模式同时命中 `WorkspaceListDivider()`，核对时用排除法。
- `git diff --numstat` 合计 86 增、86 删，24 个文件，行数不变。
- `git diff --check` 无空白错误。
- `xcrun swiftc -parse` 解析全部 24 个修改文件，退出码 0。
- 按约定未运行 swift build 或 swift test，未写实时资料库。

## 风险

- `ReflectionGraphView.swift:117` 去掉了 `text.opacity(0.12)` overlay，线色由定制色变为 `palette.border`。这是本波唯一会明显改变单条线观感的位置，集成后需目检该页头部分隔的对比度。
- 8 处竖向面板分隔仍用系统 `Divider()`，同页仍可能存在轻微色调差异。组件无竖向变体，本次约束不允许新增组件。
- 列表行间线由系统色换成 `palette.border` 后，密集列表的视觉密度会变化，尤其 `WeeklyReviewView` 的 11 处行间线与 `WorkspaceView` 的材料列表。
- `swiftc -parse` 只证明语法，不证明类型检查与运行行为。