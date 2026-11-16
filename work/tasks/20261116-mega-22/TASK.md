# 并行波 22：优化审计全量修复

目标：把 2026-11-16 审计（`work/tasks/20261116-optimization-audit/TASK.md`）列出的交互、层级、功能、性能项在一条波浪里修完。用户要求并行推进，中间不编译，最后统一构建与验证。

## 完成判据

1. 审计条目 A1–A6、B1–B9、C1–C6、D1–D5 全部落地，或在记录里写明不做的理由。
2. 合并后的树 `swift build -j 2` 与 `swift test -j 2` 一次通过（只在集成末尾跑）。
3. 实机证据：用隔离副本构建 dist 启动，覆盖改动的界面截图；性能用同一资料库复跑 `VOICEOS_STARTUP_TRACE`，前后对比，报数附运行次数与限制项。
4. PR 以 `## Why` 开头复述目标。

## 并行单元与文件所有权

每个单元一个分支与工作树，基线 `work/mega-22`。单元内不跑 `swift build` / `swift test`（用户明确要求只在最后构建），靠读码自证；测试文件照写，最后统一跑。

| 单元 | 分支 / 目录 | 独占文件 | 条目 |
|---|---|---|---|
| U1 行动行与外层 | `work/m22-a` / `.worktrees/m22-a` | `WorkspaceView.swift`（行动页与行、材料页页头）、`WorkspaceActivityViews.swift`、`SavedViews.swift` | A1 A4 A5 B1 B5 B7 |
| U2 首页 | `work/m22-b` / `.worktrees/m22-b` | `RecentContentHome.swift`、`RecentContent.swift`、`WorkspaceView.swift` 的 `.home` 讨论分支 | A2 B3 B4 C5 C6 |
| U3 应用层外壳 | `work/m22-c` / `.worktrees/m22-c` | `VoiceOSApp.swift`、`WorkspaceProcessingView.swift`、`WorkspaceView.swift` 的底部条挂载行 | A3 A6 B9 C4 D1 |
| U4 性能核心 | `work/m22-d` / `.worktrees/m22-d` | `WorkspaceSnapshot.swift`、`AssistantExecution.swift`、`RecordingFollowup.swift`、`TopicOrganization.swift`、`Store.swift` | D2 D3 D4 D5 |
| U5 界面细节与搜索 | `work/m22-e` / `.worktrees/m22-e` | `WorkspaceTopicReadingView.swift`、`TaskInitiationView.swift`、`ThoughtPanoramaView.swift`、`SearchIndex.swift`、`WorkspaceView.swift` 的搜索分组 | B6 B8 C3 全景窄窗 |
| U6 目标模型 | `work/m22-f` / `.worktrees/m22-f` | `ActionStore.swift`、`Database.swift`、`WeeklyReviewView.swift`、新增澄清视图、`WorkspaceView.swift` 的澄清入口一行 | C1 C2 |

`WorkspaceView.swift` 由五个单元触碰不同区域；合并在最后统一做，冲突由协调者解。除表内文件，不要改其他文件；共享解析器 `Sources/VoiceOSCore/StatementTag.swift` 已在基线，直接用。

## 单元决策

### U1
- 任务行左槽换成真正的完成控件（21pt 圆，点击完成，带撤销条），标题点击仍进详情；非任务行左槽保留类型图标但用 secondaryText，不用强调色。
- 悬停胶囊只保留「更多」；完成已移到左槽。悬停时不再覆盖行尾状态。
- 行菜单删「转为待办」，补「添加下一步」（复用详情页表单）与「标记达成」（确认后 completeOutcome）。`promoteAction` 保留 API，UI 入口全部移除，记录里注明。
- 状态去重：组内共享状态不进行尾。问题与目标行尾仅显示 warning 级例外与「N 个下一步」（无下一步交给顶部横幅）；待核对 tab 不逐行写「待核对」。
- 行第二行只放一个事实：有到期写到期，否则写来源；「N 个下一步」进状态槽。
- 材料页：计数进筛选标签（日常材料 69 / 未读 / 在读 …），删标题行浮动的「69 份」；阅读状态改 6pt 色点，文字只留无障碍标签。
- 性能：每行 `actionRecords.filter` 统计下一步数改为整页一次字典。

### U2
- 首页行按四槽位：左图标按 kind（waveform / doc.text / arrow.triangle.2.circlepath），槽 2 仍只放时间，槽 3 只在非默认状态（仅本地 / 整理中 / 待核对 / 在读），选中描边与 `.isSelected`。
- 「讨论」按当前页分流：最近模式用选中材料 `beginDiscussion`，全景模式用现有 selection；无可讨论项时禁用按钮并给 help，不再报错。
- 「任务进展」聚合体：标题「任务进展 · N 条」，阅读页用 sectionTitle 承载标签，第一条进展成为内容顶点；eyebrow 补时间。
- 阅读面板：eyebrow 行右侧放「回听」与「打开材料」；想法行悬停「看原话」，复用材料页的锚点跳转；长内容不再只靠页尾入口。
- 多段录音按当前 recordingExpression 合并成一条（sourceIDs 合并且去重），摘要用 expression 级 summary。
- 类型标签用 `StatementTagParser.split`。

### U3
- 底部条只在真有处理在跑（含失败待重试）时出现；「有事项需要查看」降级为侧栏「设置」上方的一个橙色小点按钮，点击进处理页。处理页上不再渲染底条，「查看处理」无动作问题随之消失。
- 处理页：共享说明提到区块 subtitle 一次；每个失败区块只保留一个「查看原因」披露与一个重试层级（>1 用批量，==1 用行内）。
- 菜单栏新增「记录」菜单（⌥⌘D / ⌥⌘V / ⌥⌘N / ⌘⇧R / ⌘I）与「显示」菜单（⌘1–⌘5、⌘[），复用现有 action；设置页快捷键清单缩到列表键（↑↓、↵、x、z、⌥⌘Z）并注明其余在菜单栏。
- `addNextAction`：表单会话持稳定 commandID（目标 id + 标题 + 表单打开 UUID）；挂接失败保留已建任务 id，错误条提供「重试挂接」，重试只调 attachNextAction，不再新建。
- `changeAction` / `saveFeedback`：写完成后立即给出状态并释放 `savingAction`；`refresh()` 与 `queueActionFollowups` 改为后台串行投递（沿用 refreshWorker），不得改变最终刷新内容。

### U4
- 每轮 briefing 1.3–1.6s：先找便宜指纹（计数 + 最大 updated_at + 已存简报键），未变即跳过 `prepareTopicOrganization`；同一轮 configure 只算一次。禁止加新表，除非证明必要。
- 助理快照 2398ms：context 屏障与 sources/claims/ledgers 每轮取一次，逐行校验复用；不得每行两次全文 JSON 编码。目标 <300ms（8 行样本）。
- 跟进 567ms + 有效性 905ms：复用快照已读数据，转写上下文按来源记忆化；不得改 schema。
- 加 `StartupTrace` 分段标记便于复测；每项在记录里写清限制项与「为什么不是两倍好」。
- 不做 schema 改动（63 归 U6）。

### U5
- 主题卡：无摘要时不留两行空位。
- 启动页：默认不展开上一条草稿（selected 初始 nil）；`text.cursor` 图标换 `square.and.pencil` 或去掉；页面顺序 新启动 → 记录列表 → 展开记录。
- 全景工具栏：窄窗（<1100pt）用 ViewThatFits 依次丢弃状态长文、把筛选与工具收进「…」菜单，搜索框不被裁切。
- 主题进搜索：`SearchHit.Kind` 增 topic，索引 `reflection_questions` 标题，指纹表加入该表；搜索页新增「主题」分组，点击 `selectTopic`；主题页超过一屏时加本地筛选框。

### U6
- 迁移 63：`actions.state` CHECK 增 `someday`；`LocalActionState` 加 `someday`；`setActionState`、修订账本、包校验、恢复校验全部接受；包格式号不变并在记录里说明。
- 逐个澄清：问题与目标页头「…」菜单加「逐个澄清」；一次一条，四个出口（达成 / 放弃 / 将来也许 / 加下一步），显示剩余数并可跳过；命令号 `clarify:<id>:<exit>:<version>` 幂等。
- 将来也许回看：每周回顾加区块，列出 60 天未回看的 someday 项；回看动作写修订账本 note「回看」，不新增列；出口为恢复为目标或放弃。
- 测试：迁移 63、三态到四态转移、澄清回执幂等、回看查询。`TestSchema.currentVersion` 升 63。

## 共享规则

- 遵守 poteto-mode：`/Users/joey/.claude/plugins/cache/cursor-plugins/pstack/0.15.36/skills/poteto-mode/SKILL.md`（先读它）。
- 只在所属工作树里改文件；绝不触碰主检出 `/Users/joey/01 Projects/VoiceOS` 与实时资料库。
- 不跑构建与测试；提交到自己的分支，提交信息用中文一句话加常规前缀（feat/fix/perf/docs/test）。
- 报告：改了哪些文件、每个审计条目的落点（file:line）、新增测试文件名、未决点。不要贴大段代码。
