# 波 43：录音计时与丢弃、空转写入待核对

来源：发现者 G 提案 3（录音无计时无丢弃、菜单栏静态红点）与其低垂果实（空转写静默 completed）。

## 完成判据

1. 录音中可见时长：菜单栏状态项与菜单项标题显示 mm:ss（「正在录音 02:31」），窗口录音条显示计时；停止后计时消失。
2. 「取消并丢弃」：录音条提供丢弃入口，二次确认后删除 staging 录音、材料置为已丢弃（移入回收站或等价安全状态），不再进入转写与整理；菜单栏菜单提供同一动作。
3. 空转写不再静默完成：转写结果为空文本时，job 标记为需核对（或在处理页出现「转写为空」事项），处理页可看到并可重新转写或移入回收站；不再出现「completed 且当前转写为空」的材料。
4. swift build 与 swift test 真实退出码 0（481 项基础上新增空转写测试）。

## 共享契约

- RA：计时只依赖现有录音状态（dictationActive 起始时间）；丢弃路径复用既有 staging 删除与回收站通道，绝不留下可被恢复入队的 job。
- EB：空判定沿用现有 SpeechText.validate 语义（空白文本即空）；不改变非空转写的一切行为；不新增 schema（job 状态列已有取值空间则用之，否则在处理页以查询推导，报告说明）。
- 文件不重叠：RA 在 App 层状态项与菜单；EB 在核心校验与处理页。

## 单元与文件所有权

| 单元 | 分支 / 目录 | 独占文件 | 内容 |
|---|---|---|---|
| RA 计时与丢弃 | `work/m43-ra` / `.worktrees/m43-ra` | `Sources/VoiceOSApp/VoiceOSApp.swift`、`Sources/VoiceOSApp/AppBrand.swift` | 判据 1、2 |
| EB 空转写 | `work/m43-eb` / `.worktrees/m43-eb` | `Sources/VoiceOSCore/Models.swift`、`Sources/VoiceOSCore/Store.swift`（转录 job 路径）、`Sources/VoiceOSApp/WorkspaceProcessingView.swift`、`Tests/VoiceOSCoreTests/`（转写相关） | 判据 3 |

规则同前：只在所属工作树改文件，不跑构建与测试，不碰主检出与实时库，提交信息结尾固定一行 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 决策细节

- RA：G 证据——状态文案固定（WorkspaceProcessingStatus.swift:68-70）、状态项只设图片与 toolTip（VoiceOSApp.swift:3698-3705）、红标静态（AppBrand.swift:43-52）、无任何取消入口。计时用 TimelineView 或 1s 定时器，报告说明选择；丢弃需处理 dictationActive 中的状态机（先停再删）。
- EB：G 证据——2026-10-12 一份 11.4 秒口述的当前转写版本为空且 job completed；SpeechText.validate 不拒绝空文本（Models.swift:100-113）。标记方式读码决策（job error 或 state 需核对变体），处理页给「重新转写 / 移入回收站」。
- 协调者纪律：构建与测试后台直跑并记录真实退出码；重启先过 scripts/app/restart_preflight.sh。

## 验证基线

- 实时库：80 个 transcription job 全 completed；已知 1 份空转写（2026-10-12，11.4 秒）。
- 用户随时可能用机器：重启进空闲窗口。

## 结果（完成后填）

## 追加：发现者 I 与单元 P1（过期主题整页退化，影响 5）

实时证据：28/28 个主题的 organization 版本校验不通过（52/52 条 sourceVersions 不符），读端直接把 organization 丢弃，主题页概览、认识与问题、行动与结果三个 tab 全部退化成「尚未生成结构卡片」，网格也只剩材料数；reflection_questions 全部停在 2026-10-20，而 transcript_versions 有 64 条晚于 10-20（最新 11-17）。自动排队存在（VoiceOSApp:903-931，刷新末 1444-1446 调用）但从未重写；组织器按 digest 判重与读端按版本判新两套口径疑似不一致（推断）。

### P1 单元（追加进本波）

- 文件（独占）：`Sources/VoiceOSCore/ReflectionQuestions.swift`、`Sources/VoiceOSCore/TopicOrganization.swift`、`Sources/VoiceOSApp/WorkspaceTopicReadingView.swift`。不改 VoiceOSApp.swift / Models.swift / Store.swift（RA、EB 独占）；若重排必须动 VoiceOSApp，先只改核心并报告所需接口，集成时协调。
- 判据 8：过期主题保留旧组织并展示「材料已更新，待重新整理」横幅（网格与详情页同口径），不再整页清空；有旧卡时旧卡可读，行动/原话跳转照常。
- 判据 9：重排口径统一——组织器的判重条件与读端校验使用同一新旧标准；过期主题实际会进入重排（可用核心测试证明判重放行），不再出现「永不重写」。
- 测试：过期但保留展示、口径一致（组织器放行 + 读端可用）、未过期主题行为不变。

## 结果（2026-11-17 深夜）

- RA：录音中状态项右侧显示 mm:ss（1 秒 Timer，common 模式，菜单打开也走）、菜单项标题带时长与快捷键、停止后即时停表；菜单「取消并丢弃本次口述…」（NSAlert 默认继续录音）→ 停录、删音频、quarantine 置 blocked、材料进回收站、不入队不转写；残余亚秒竞态（转写 worker 在 seal 与 quarantine 之间认领）已记录。集成补完：窗口录音条 TimelineView 计时 + 「取消并丢弃…」确认按钮（VoiceOSProcessingView 由协调者接线）。
- EB：空文本转写不再以 completed 静默收尾——job 置 blocked 并写标记错误；处理页「转写为空」区块（材料名、时长、时间、重新转写、移入回收站）；历史空转写纯查询识别（已知 1 份 2026-10-12）；4 条测试。
- P1（影响 5）：28/28 主题因版本校验失败整页退化的根因修复——读端保留可解码组织并写 organizationStale，详情页与网格显示「材料已更新，待重新整理」横幅；组织器判重与读端共用同一校验（topicOrganizationsAreCurrent + 公共 needsTopicOrganizationRefresh），自动重排守卫改为同一判据（集成时改 VoiceOSApp:917）；3 条核心测试。既有 CoreFlowTests 两条「过期即隐藏」断言对齐新语义（保留展示 + stale 标记）。
- 验证（真实退出码）：swift build 0（Build complete! 73.57s）；swift test 0，488 项 0 失败（481 基础上新增 7）。
- 已知边界（P1 报告）：若模型始终不返回某旧主题 ID，该主题保持过期并反复触发整理，后续波次加清理策略。
