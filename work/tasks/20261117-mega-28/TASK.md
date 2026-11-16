# 并行波 28：主题修复、全景搜索、转写审计与疑点队列

来源：第四轮两路发现（主题与全景 9 点、材料导入与转写核对 9 点）。数据事实：重命名主题会清空该主题的 AI 组织并把全库整理重新排队；全景搜索只有「N 个区域匹配」没有结果列表（当前 70 区 150 问）；40 份材料 841 处自动改写被清空不可审计；50 份核对完成材料里 26 份带 239 条未解决疑点却没有任何队列入口。

## 完成判据

1. 重命名主题不再清空已生成的 AI 组织（摘要、小节、阅读卡片保留），title/title_source/ai_named 照常更新；补测试断言重命名后 organization 不变。
2. 全景搜索给出可点结果列表：按当前 query 过滤区域与问题，点行聚焦；无匹配时给「显示全部」。
3. 转写改写可审计：保存核对后 corrections 不再清空；材料核对区显示改写数量，展开可见 before → after 列表（默认折叠）。
4. 纠错影响前置：保存更正成功后若受影响的行动非空，材料页显示「N 项任务受影响」并可打开纠错影响（复用现有 CorrectionImpactView 模型）。
5. 未解决疑点有队列：处理页新段「转写疑点待核对」按份数与条数派生，可进入材料；首页材料行状态槽对 unresolved 非空显示「疑点 N」；材料列表行同样显示。
6. 合并后 `swift build -j 2` 与 `swift test -j 2` 一次通过（422 项基础上新增）。

## 共享契约

- 主题重命名：ReflectionQuestions 的重命名 UPDATE 保留 organization_json，只更新标题相关字段。
- 全景搜索：结果行点击复用现有定位/聚焦通道；过滤数据用区域的 searchText 与问题文本，符号与现有 searchMatches 一致。
- corrections 保留：保存核对不再清空 corrections；界面读取 presentation JSON 现有字段（字段名以现状为准），只展示当前 transcriptVersionID 的一版。

## 单元与文件所有权

| 单元 | 分支 / 目录 | 独占文件 | 内容 |
|---|---|---|---|
| R 主题与全景 | `work/m28-r` / `.worktrees/m28-r` | `ReflectionQuestions.swift`、`ThoughtPanoramaView.swift`、其测试 | 判据 1、2 |
| S 转写审计 | `work/m28-s` / `.worktrees/m28-s` | `RecordingPresentation.swift`、`WorkspaceSourceView.swift` | 判据 3、4 |
| T 疑点队列 | `work/m28-t` / `.worktrees/m28-t` | `WorkspaceProcessingView.swift`、`WorkspaceView.swift`、`RecentContentHome.swift` | 判据 5 |

规则同前：只在所属工作树改文件，不跑构建与测试，不碰主检出与实时库，提交到自己的分支，提交信息结尾固定一行 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 决策细节

- R：先改重命名 UPDATE（ReflectionQuestions.swift:137 一带）再补测试；全景结果列表放 outlinePanel 顶部（ThoughtPanoramaView.swift:439 一带，接当前 query），行点击复用 recenter。
- S：RecordingPresentation.swift:148-149 的置空行为删除；核对区（WorkspaceSourceView.swift:594 一带）加「改写 N 处」折叠列表，before → after 每行带上下文引文截断；纠错影响提示条放在材料页保存反馈之后，用现有 model.correctionImpacts 数据。
- T：处理页新段派生自 records 的 transcriptionReview（unresolved 非空即计入份数与条数），行点击 openSource；首页状态槽优先级排在「待核对」之后；WorkspaceView 材料行（约 1547 行）同样给「疑点 N」状态。T 是本波唯一改 WorkspaceView 的单元。

## 验证基线

- 实时库：28 主题（全部 AI 命名、28/28 组织载荷、91 小节）、全景当前部分快照 70 区 150 问 0 联系、50 份核对含 26 份 239 条疑点、40 份 direct_ai 841 处改写、34 份材料被改写。
- 锁屏仍在，交互截图待解锁统一补拍。
