# 波 127-A：反思/练习/提醒区说明文字压缩与间距节奏

基线 `main`@`920705a`，工作树 `.worktrees/m127-a`，分支 `work/m127-a`。目标：按用户反馈删掉不承担信息的小字说明，并让同组间距小、区块间距大。间距只用 `WorkspaceMetrics` token。

约束：只改清单上的 12 个视图文件；不新增组件；不改 `WorkspaceDesign.swift`；不运行 `swift build` / `swift test`。

## 文案删除（5 条）

- `Sources/VoiceOSApp/ReflectionTimelineView.swift:115` 删 `尚无当前有效的整理内容；可以打开全文查看表达。`。上方按钮已给出"查看…全文"，卡片标签也显示思考与任务计数。
- `Sources/VoiceOSApp/ReflectionGraphView.swift:508` 删 `你带来经历与判断，VoiceOS 帮你找回联系、提出问题。一起回顾后，可以继续讨论并保留有价值的认识。`。宣传句，无操作或事实信息。
- `Sources/VoiceOSApp/EnglishPracticeView.swift:51` 删 `反馈独立保存，不创建认知候选、行动或提醒事项。`。内部机制，界面无对应操作。
- `Sources/VoiceOSApp/Onboarding.swift:17` 删第 3 步 detail `常用三条，随时可用。`，`detail` 置空。渲染处改为 detail 非空才显示。
- `Sources/VoiceOSApp/WorkspaceDiscussionView.swift:54` 删 `带着眼前的内容继续想。输入问题后直接发送。`。复述下方输入框与发送按钮。

## 文案压缩（13 条）

- `ReflectionTimelineView`：完成登记卡只留 `不代表已取得收获。`；任务块只留 `不代表任务在这一天完成。`。
- `ReflectionGraphView`：图例点击提示与四种边解释移入 `.help()`；概览/周期说明各压成一句；完成登记与任务状态两句压短。新增私有 `edgeExplanation(_:)` 承载边说明，`AI 关联` 复用已有文案 `AI 关系判断 · 待核对`，不新增句子。
- `ReflectionChangeView`：依据说明压成一句；发送说明压成一句。
- `RecordingFollowupView`：来源提示压成 `先选择来源录音，再生成跟进。`；英语空态压成一句。
- `Onboarding`：`更多快捷键见「设置 › 键盘快捷键」。` 移入快捷键块 `.help()`。
- `ReminderScheduleViews`：本地期限说明压短，保留"只本地保存、不自动改外部提醒"的政策事实。

BilingualView、ReminderSettingsView、ClaimNoteViews 的文案条目全部保留，未改。

## 间距结构（20 项）

- `ReflectionTimelineView`：搜索与统计 `rowGap`；统计与列表 `sectionGap`；卡间 `rowGap`；日期标题上下 `groupGap - rowGap`（8+10=18）；完成登记卡内 `rowGap`。
- `ReflectionGraphView`：页头 `sectionGap`；inspector `groupGap`。
- `ReflectionChangeView`：主块 `sectionGap`；追问组内 `rowGap`。
- `RecordingFollowupView`：页头、控件组、列表之间 `sectionGap`，控件组内 `rowGap`；列表卡间 `rowGap`；回执标题上下 18；目标列表 `rowGap`。
- `EnglishPracticeView`：顶层 `sectionGap`；预览列表 `rowGap`；旧练习标签与列表 `rowGap`。
- `BilingualView`：顶层 `sectionGap`。
- `Onboarding`：两层 `sectionGap`；检查清单 `rowGap`。
- `ReminderScheduleViews`：两个表单改为 `sectionGap` 分区块，组内 `controlPadding`（12）。
- `ReminderSettingsView`：四个分区组内 12，Divider 两侧与区块之间 `sectionGap`（28）。
- `WorkspaceDiscussionView`：依据行 vertical padding 6 改 4（清单指定字面量，非 token）。

## 未采纳

无。逐条复核后，清单 70 条（删除 5、压缩 13、保留 52）与源码上下文一致，全部执行。

删除前全仓 grep 了每条待删文案，命中只在本文件自身，测试与无障碍标识不依赖。

## 验证

- `git diff` 逐处复核：括号层级、缩进正确，改动只落在清单文件。
- `git diff --check`：无空白错误。
- 未运行 `swift build` / `swift test`（任务约束），未跑应用做视觉核对。

## 风险

- 视图重排是结构改动，语法与布局需集成交付前的完整构建与视觉核对确认。
- 18 间距用 token 算术 `groupGap - rowGap` 得到补偿 padding 10，未新增常量。
- 删除提示后，讨论区与时间线空态少一句引导；输入控件与全文按钮仍原位可见。
- `Onboarding` 第 3 步 detail 置空依赖新增的条件渲染；`onboardingSteps` 仅本文件使用。