# 126-C 小字清扫与间距节奏

任务依据：用户指出软件里解释性小字过多，且同类信息与不同区块之间的间距没有拉开层次。

改动范围（6 个文件，其余不动）：
- `Sources/VoiceOSApp/WorkspaceTopicReadingView.swift`
- `Sources/VoiceOSApp/ThoughtPanoramaView.swift`
- `Sources/VoiceOSApp/WorkspaceProcessingView.swift`
- `Sources/VoiceOSApp/DiscussionView.swift`
- `Sources/VoiceOSApp/KnowledgeReviewView.swift`
- `Sources/VoiceOSApp/ReflectionQuestionsView.swift`

未修改 `WorkspaceDesign.swift` 与 `WorkspaceTheme.swift`，未新增组件。间距一律使用既有 `WorkspaceMetrics.rowGap / groupGap / sectionGap`。

## 一、小字裁决

### 删除（3 条）

| 文件:行 | 原文 | 理由 |
| --- | --- | --- |
| WorkspaceTopicReadingView.swift:247 | 连线表示主题下的内容分组 | 解释装饰连线，界面本身已表达层级 |
| ThoughtPanoramaView.swift:469 | 与画布一致；键盘可逐项浏览。 | 解释内部实现与通用键盘行为 |
| WorkspaceProcessingView.swift:496 | 查看暂停原因、受影响的任务和处理按钮（行副标题） | 复述行内已有内容，改为状态词「待核对」 |

### 压缩（22 条）

| 文件:行 | 原文 | 改后 |
| --- | --- | --- |
| WorkspaceTopicReadingView.swift:188 | 主题骨架已完成；正文按主题分批生成，已完成的会逐批出现并保留。 / 完整材料已保留；整理后会显示要点、原话与行动。 | 正文分批生成，已完成的部分会保留。 / 原文已保留；整理后会显示要点、原话与行动。 |
| WorkspaceTopicReadingView.swift:517 | AI 交付 · 实践效果见实际记录 | AI 交付 |
| ThoughtPanoramaView.swift:700 | 这是已核对区域。其余完整单元、跨单元联系与全局覆盖尚未完成；当前结果不代表本人认可。 | 仅显示已核对区域；跨单元联系与全局覆盖尚未完成，不代表本人认可。 |
| ThoughtPanoramaView.swift:702 | 输入不按近期或条数裁剪。仅完整整理、当前版本与许可均有效的材料入选；节目依赖单独计数。AI 未归入项仍保留完整入口。 | 只选入完整整理、当前版本且许可有效的材料；未归入项仍保留入口。 |
| ThoughtPanoramaView.swift:1116 | 对联系有异议，可沿线讨论。原话与理解更正分别返回材料的正式更正入口。 | 对联系有异议，可沿线讨论；更正请在材料中进行。 |
| ThoughtPanoramaView.swift:1251 | 带入相关完整表达与节目原文，先打开可编辑的 AI 候选草稿；点击发送后才成为你的提问。 | 带入相关完整原话；发送后才成为你的提问。 |
| WorkspaceProcessingView.swift:279 | 保持应用运行即可继续处理；可以先阅读其他内容。原文、处理结果与历史分别保留。 | 保持应用运行即可继续处理；原文、处理结果与历史分别保留。 |
| WorkspaceProcessingView.swift:399 | 录音被中断时已保存的片段仍保留；本地转写失败时原件仍保留。 | 中断录音的已保存片段和转写失败的原件都会保留。 |
| WorkspaceProcessingView.swift:467 | 模型输出未通过本地校验，原文与旧处理记录保留。整批重试会作为新的处理任务发送，不覆盖这次记录。 | 模型输出未通过本地校验，原文与旧记录保留；整批重试会新建处理，不覆盖这次记录。 |
| WorkspaceProcessingView.swift:492 | 以下事项尚未登记完成，行动关系待核对或 AI 提取已暂停。逐条核对：同一件事会接回原记录，两件事会保留两条；核对后即可继续同步。 | 这些待办尚未登记完成或关系待核对；核对后即可继续同步。 |
| WorkspaceProcessingView.swift:547 | （数据句）。打开材料可以逐条回听原音与查看原文。 | 常驻行只留数据句，操作提示移入 `.help`（见下节） |
| WorkspaceProcessingView.swift:729 | 只保留本次运行最近 5 条；点开可查看对应材料。 | 只保留本次运行最近 5 条。 |
| WorkspaceProcessingView.swift:741 | 本次运行还没有完成记录；长任务完成后会保留最近 5 条，错过通知也能在这里找回。 / 以上是最近完成的记录，可点开查看材料。 | 本次运行还没有完成记录；最近 5 条会保留在这里。 / 以上是本次运行最近完成的记录。 |
| DiscussionView.swift:45 | 以进入时选定的资料为依据，早期资料作为背景；新记录可从认知地图重新进入回顾。 | 以进入时选定的资料为依据。 |
| KnowledgeReviewView.swift:33 | 对照原话检查事实、推断与适用条件。以下是有依据的 AI 核查建议，是否采纳由你决定；可标为已读、认可或驳回，已认可与已驳回的建议默认折叠。 | 对照原话检查事实、推断与适用条件；建议是否采纳由你决定。 |
| KnowledgeReviewView.swift:82-83 | 本次未提出需要纠偏的知识判断。 / 这不代表全文全部正确；当前核查可能仍有遗漏。 | 本次未提出需要纠偏的知识判断；这不代表全文正确，核查可能仍有遗漏。 |
| KnowledgeReviewView.swift:85-86 | 本条思考暂无可按连续原话定位的核查建议。 / 来源中其他判断的核查可在资料详情查看，未关联到这里。 | 本条思考暂无可按连续原话定位的核查建议；其他判断的核查见资料详情。 |
| ReflectionQuestionsView.swift:91 | 例如：Agent 记忆，或怎样让 AI Agent 稳定完成真实任务？\n主题与问题都可以承载持续的探索。 | 只保留示例句 |
| ReflectionQuestionsView.swift:182 | 回顾这个周期的进展，同时带上已关联的完整历史作为依据；下方记录仍显示整个主题。 / 沿着整个主题探索，不按日历截断。已关联的完整资料、个人记录与成果共同构成讨论依据。 | 回顾这个周期；下方记录仍显示整个主题。 / 沿整个主题探索，不按日历截断。 |
| ReflectionQuestionsView.swift:191 | 先关联一份材料，或留下你现在的理解。以后可以回来对照它如何变化。 | 先关联一份材料，或留下你现在的理解。 |
| ReflectionQuestionsView.swift:270 | 可以写一个主题，也可以写一个具体问题。无需问句；相关资料、想法与实践以后逐渐加入。 | 可以写一个主题，也可以写一个具体问题；资料、想法与实践以后逐渐加入。 |
| ReflectionQuestionsView.swift:307 | 从原文、已有知识或任务接回主题，时间不限。关联保留原话与归属，不代表认可观点或完成任务。 | 从原文、已有知识或任务接回主题；关联保留原话与归属，不代表认可。 |

### 移入 help（1 条）

`WorkspaceProcessingView.swift:547` 的「打开材料可以逐条回听原音与查看原文」移入同文本的 `.help(...)`，常驻可见行只保留数据句。该行同时计入上面的压缩。

### 保留未动（抽样）

- 政策与授权：DiscussionView 的发送、整理、提醒清单授权说明；KnowledgeReviewView 的「仅本地」与「不代表认可」；ThoughtPanoramaView 的「AI 的推断，不是你的结论」。
- 失败、断连、暂停与只读状态说明：WorkspaceProcessingView 各失败卡片的状态与数据保留说明。
- 不可逆操作提醒：结束讨论、取消并丢弃录音、移入回收站等 alert 文案。
- 空态文案：只保留一句，删除第二句解释。

## 二、间距节奏

### sectionGap 28

- WorkspaceTopicReadingView 的 body 与 actionResults 顶层 VStack：24 改为 28。
- WorkspaceProcessingView 页面根 LazyVStack：24 改为 28。
- ThoughtPanoramaView 三个 reader 面板（Region、Question、RelationInspectorPanel）顶层 VStack：16 改为 28。

### groupGap 18

- DiscussionView 模态根 VStack：12 改为 18；正文 VStack：16 改为 18。
- ThoughtPanoramaView 空态组合：18 改用 token；覆盖弹窗根 VStack：14 改为 18。
- ReflectionQuestionsView 的 questionList、detail、createSheet、sourcesSheet：16 改为 18。

### rowGap 8

- WorkspaceTopicReadingView：结构网格 12 改为 8；阅读卡片网格 16 改为 8（两处）；观点列表 12 改为 8；展开观点 16 改为 8；原话依据 12 改为 8；问题列表 16 改为 8；连接行、个人记录行、行动结果行的纵向 padding 16 改为 8；探索意图行 padding 12 改为 8。
- ThoughtPanoramaView：大纲列表 10 改为 8；其他原话列表 10 改为 8；覆盖清单 12 改为 8。
- WorkspaceProcessingView：待补理解的行组 10 改为 8。
- KnowledgeReviewView：来源核查块 10 改为 8；问题列表 10 改为 8。
- ReflectionQuestionsView：记录列表 12 改为 8；资料列表 12 改为 8。

### 卡片内部 12

- WorkspaceTopicReadingView 的主题速览、内容结构、阅读卡片、主题瓦片：16 改为 12。
- KnowledgeReviewView 的问题卡片：11 改为 12。

### 有理由的例外

1. DiscussionView 模态根用 groupGap：固定 780 高，标题、历史选择与正文属于同一操作流，sectionGap 会挤压正文。
2. ThoughtPanoramaView 覆盖弹窗根用 groupGap：标题与统计行同属头部组，sectionGap 会把同组拆开。
3. ReflectionQuestionsView 的 detail 与两个表单用一个 VStack 承载头部组和密集控件。拆分子组属于布局改动，超出本次范围，故取 groupGap。
4. 卡片内部统一 12：同一 VStack 无法单独设置「标题到首行正文」的 8 至 10，12 落在卡片内块间距区间内。
5. 横向 HStack 间距与按钮命中区 padding（如 20、12）不按纵向节奏处理，保留防误触空间。

## 三、验证

- `xcrun swiftc -parse` 对 6 个文件逐个返回 0，仅语法检查。按任务约束不运行 `swift build` 与 `swift test`，集成阶段统一构建。
- `git diff --stat` 只涉及上述 6 个文件。
- 删除的文案用 grep 复核，文件中不再出现。