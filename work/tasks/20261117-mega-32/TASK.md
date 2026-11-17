# 并行波 32：材料与导入细节、回答就地追问

来源：材料导入与主题两路发现的剩余项，加「问题先回答」的最后一层：回答本身不能追问。

## 完成判据

1. 合并材料的标题编辑作用于分组标题：同一分组在编辑器预填、页面标题与列表行显示同一标题；分组手动标题持久（RecordingExpression 加 manualTitle 小字段，JSON 内，无迁移）；单段材料编辑行为不变。
2. 材料菜单加「重新判断连续表达」与「拆为独立录音」：以选中集合为范围复用现有 prepare/connect 通道；拆分后各段恢复独立标题；分组不可用时显示原因而不是静默隐藏。
3. 主题页头显示「标题取自《材料名》」，点击打开来源材料（数据用现有 title source 关联）。
4. 材料页「未归入主题」的折叠组标题行加「交给 AI 归组」（复用 queueTopicOrganization），并给未归原因（无理解回执等已有原因字段）。
5. 问题就地追问：完成态回答下有追问输入框；提交后产生携带 instruction 的 analysis 执行（fresh 语义，排队中立即显示「追问已排队」）；历史追问按时间列出、可展开读结果；原回答仍在顶点；「AI 的工作与交付」不重复列出这些追问（沿用波 24 的过滤）。
6. 合并后 `swift build -j 2` 与 `swift test -j 2` 一次通过（431 项基础上新增）。

## 共享契约

- 分组标题：RecordingExpression 增加 `manualTitle: String?`；renameRecording 在表达式上下文写它；显示优先级 manualTitle > 自动标题 > 成员标题。旧数据解码为 nil。
- 拆分/重判：复用 prepareRecordingExpressions / connectRecordingExpressions 范围语义；命令幂等（沿用既有 commandID 规则）；不做多对多谱系。
- 追问：AssistantExecution 入队对 analysis 允许 instruction 非空（空字符串保持现行为），fresh 语义不变；执行输入 references 沿用原回答的 references 快照；界面只读展示。
- 未归组：原因来自 panoramaInput/exclusions 同源或主题链接侧派生，选实现最简且不新增查询的一处。

## 单元与文件所有权

| 单元 | 分支 / 目录 | 独占文件 | 内容 |
|---|---|---|---|
| D1 材料与导入 | `work/m32-d1` / `.worktrees/m32-d1` | `RecordingPresentation.swift`、`WorkspaceSourceView.swift`、`WorkspaceView.swift`、其测试 | 判据 1、2、3、4 |
| D2 就地追问 | `work/m32-d2` / `.worktrees/m32-d2` | `VoiceOSApp.swift`、`AssistantExecution.swift`、`QuestionAnswerSection.swift`、`WorkspaceActivityViews.swift`、其测试 | 判据 5 |

规则同前：只在所属工作树改文件，不跑构建与测试，不碰主检出与实时库，提交到自己的分支，提交信息结尾固定一行 `Co-Authored-By: Claude 5.5 <noreply@anthropic.com>`。

## 决策细节

- D1：标题编辑器（RecordingTitleEditor）在分组上下文预填分组标题并写回 manualTitle；拆分入口放在材料行菜单与详情菜单各一处；「标题取自」放在主题页头标题下方，sourceID 取现有 title_source_id。
- D2：追问执行以原问题的 action 为锚、mode=analysis、instruction=用户输入、fresh=true；回答区块显示「追问记录（N）」折叠列表（每条显示指令与结果摘要，可展开全文）；排队与运行态实时刷新沿用现有 assistantExecutions 发布；模型未配置时输入框禁用并说明。

## 验证基线

- 实时库：31 个分组（12 个多段、最多 3 段）、52 份材料未归主题、5 条完成分析、28 个主题。
- 锁屏仍在，交互截图待解锁统一补拍。
