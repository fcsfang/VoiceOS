# 波 44：启动页步骤回链与草稿续接、主题页相邻入口

来源：发现者 I 提案 2、3、4（P1 已在波 43 交付）。

## 完成判据

1. 启动页「记下这一步」回链：结果包下方列出该记录已保存的步骤（标题、时间、打开来源），按 command_id 前缀 `initiation-step:<记录ID>:` 派生、零 schema；历史副标题显示「记下 N 步」；无步骤时不显示区块。
2. 启动页进入时自动选中最近一条未复制草稿并滚到结果包（无草稿则维持现行为）。
3. 已确认（confirmed）的启动记录有归档出口（菜单或按钮），归档后从默认列表隐藏、可切换查看；不改草稿、复制、确认的既有语义。
4. 主题阅读页新增「相邻主题」区：按共享材料数排序（≥1 条共享），点击走既有 selectTopic 跳转；无共享时整段隐藏。
5. swift build 与 swift test 真实退出码 0（488 基础上新增，如核心有变化）。

## 共享契约

- 步骤回链（TA）：读取只按 sources.command_id 前缀（先例 RecordingExpression.swift:110）；写入端 TaskInitiationView.swift:287 的前缀格式不动；派生查询放核心 TaskInitiation.swift，可测试。
- 归档（TA）：实现里若无现成状态位，用既有状态空间表达（如 presentation 字段或新查询推导），不改 SQL 表结构、不加迁移；报告说明选择。
- 相邻主题（TB）：数据用既有 workspaceTopicSources；跳转用既有 selectTopic；主题页文件在波 43 刚改过（横幅），勿动横幅逻辑。
- 两单元文件不重叠。

## 单元与文件所有权

| 单元 | 分支 / 目录 | 独占文件 | 内容 |
|---|---|---|---|
| TA 启动页 | `work/m44-ta` / `.worktrees/m44-ta` | `Sources/VoiceOSApp/TaskInitiationView.swift`、`Sources/VoiceOSCore/TaskInitiation.swift`、`Tests/VoiceOSCoreTests/TaskInitiationChecks.swift` | 判据 1、2、3 |
| TB 相邻主题 | `work/m44-tb` / `.worktrees/m44-tb` | `Sources/VoiceOSApp/WorkspaceTopicReadingView.swift`、`Sources/VoiceOSApp/WorkspaceView.swift`（仅 selectTopic 相关接线） | 判据 4 |

规则同前：只在所属工作树改文件，不跑构建与测试，不碰主检出与实时库，提交信息结尾固定一行 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 决策细节

- TA：I 证据——前缀写入 TaskInitiationView.swift:287、读取点全仓为零、库内 0 条步骤材料；TaskInitiationRecord 无步骤字段（TaskInitiation.swift:97-112）。自动选中：selectedID 初始 nil（TaskInitiationView.swift:18），只有生成与点击会选中；最近 1 条 draft 记录 11-13 创建、4.2 天未动。confirmed 后 discard 被拒（TaskInitiation.swift:397-401），界面只显示「已确认 · 尚未执行」。
- TB：I 证据——16/28 主题共享材料、主题页无任何其他主题引用、交叉点只在材料页（WorkspaceSourceView.swift:710-715）、数据现成（workspaceTopicSources）。排序按共享材料数降序、并列按主题名。
- 协调者纪律：构建与测试后台直跑并记录真实退出码；重启先过 scripts/app/restart_preflight.sh。

## 验证基线

- 实时库：task_initiations 1 条（draft/agent_handoff、未复制）；步骤材料 0 条；主题 28、跨材料 16、8 个主题挂 3 份材料。
- 用户随时可能用机器：重启进空闲窗口。

## 结果（完成后填）
