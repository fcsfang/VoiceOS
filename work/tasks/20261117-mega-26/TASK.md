# 并行波 26：每周回顾、处理与注意力、恢复与系统集成

来源：第三轮两路发现（每周回顾与任务执行 9 点、系统集成与数据健康 9 点），按影响除以成本取。数据事实：近 7 天完成 21 条、回顾页只能看到 2 条反馈；62 个目标全部「没有下一步」且回顾里只展示不解决；全景生成 21 次尝试 0 成功（17 failed、4 unknown）但处理页不显示；恢复迁移包会把排队中的 AI 委托自动续跑。

## 完成判据

1. 每周回顾有「本周完成」：近 7 天 completedAt 清单（标题、完成日期、来源），排在反馈行之前；20 条无结果的完成可通过已有待补结果入口触及。
2. 回顾「暂停与冻结」段只留 workspacePausedTasks；该段与其它段落的「查看全部」落点与计数口径一致（落错过滤器的修落点或改文案）。
3. 回顾的停滞目标段可打开逐个澄清（goals 范围，复用现有队列）；行尾有「加下一步」；回顾行标题用 StatementTagParser 去标签。
4. 全景 failed/unknown 进入处理情况页与注意力聚合（侧栏圆点亮起），段落带重试；处理页错误按类别显示中文（解码/网络/其它），失败项可「忽略这次」或「停止处理」（复用已有 cancel 接口）；页尾有「已全部处理」清空态。
5. 恢复迁移包时 queued/running 的 assistant_executions 冻结为 failed（文案：迁移前委托尚未完成，可手动重试），恢复后不自动执行。
6. Spotlight 的行动与材料条目携带 contentURL（voiceos://action/<id>、voiceos://source/<id>），应用路由到具体条目。
7. 提醒事项权限被拒时设置页给「打开系统设置」深链；区分 denied 与未询问。
8. 新增 AppShortcutsProvider 暴露四条意图的中文短语；CaptureTextIntent 带 parameterSummary。
9. 迁移包版本过新给专门文案（此包由更新版本的 VoiceOS 创建，请升级后再恢复），与格式损坏、schema 不匹配分开。
10. 菜单栏加「行动 › 每周回顾」命令。
11. 合并后 `swift build -j 2` 与 `swift test -j 2` 一次通过（418 项基础上新增）。

## 共享契约

- NativeReminders 新增授权状态：`public enum RemindersAuthorization { case granted, denied, notDetermined }` 与读取函数；既有抛错路径保持兼容。单元 L 的界面在 denied 时给系统设置深链 `x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders`。
- Spotlight：行动条目 contentURL `voiceos://action/<id>`，材料条目 `voiceos://source/<id>`；单元 L 在 routeExternalURL 加对应分支跳到任务页/材料页。
- 全景注意力：把全景尝试的 failed/unknown 计数并入 workspaceNeedsAttention 的派生；处理页新段落用现有全景重试入口，不改全景执行器。
- 恢复冻结：populateRestore 内把 queued/running 执行改为 failed 并写中文 error；不改执行器与队列表结构。

## 单元与文件所有权

| 单元 | 分支 / 目录 | 独占文件 | 内容 |
|---|---|---|---|
| K 每周回顾 | `work/m26-k` / `.worktrees/m26-k` | `WeeklyReviewView.swift` | 判据 1、2、3 |
| L 处理与注意力 | `work/m26-l` / `.worktrees/m26-l` | `WorkspaceProcessingView.swift`、`WorkspaceView.swift`、`VoiceOSApp.swift` | 判据 2 的落点修复（如需）、4、6 的路由分支、7 的界面、10 |
| M 恢复与集成 | `work/m26-m` / `.worktrees/m26-m` | `PortablePackage.swift`、`SpotlightIndexer.swift`、`NativeReminders.swift`、`AppIntents.swift` | 判据 5、6 的条目、7 的状态、8、9 |

规则同前：只在所属工作树改文件，不跑构建与测试，不碰主检出与实时库，提交到自己的分支，提交信息结尾固定一行 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 决策细节

- K：「本周完成」直接用 ActionRecord.completedAt 过滤近 7 天，按完成时间倒序，条目带来源材料名（自寻现有名称来源）；无结果条目不缺省隐藏。暂停段与历史段分开，`allButton(.history)` 的落点改为「待核对」或改文案为「去历史记录（全部）」二者取一，保持用户预期。
- L：全景状态在 PanoramaScreenModel（VoiceOSApp.swift:22）；注意力聚合在 workspaceNeedsAttention（WorkspaceProcessingView.swift:88-94）；处理页每类错误加中文映射与动作按钮；「忽略这次」的持久化先用既有 cognitive_feedback_ignores 或 UserDefaults（写入点的选择在报告里说明）。菜单项用 CommandGroup 放「行动」相关位置，触发 WorkspaceView 的每周回顾弹窗（复用现有 showingWeeklyReview 通道，必要时加 delegate 方法）。
- M：恢复冻结放在 populateRestore 的既有冻结块旁（jobs/processing_intents/knowledge_reviews 已冻结，补 assistant_executions）；包版本判断在格式与 schema 判断之前，各给一句。Spotlight 指纹缓存顺带说明（不必修内存缓存，除非顺手）。AppShortcutsProvider 短语用中文，四条意图沿用现有名称。

## 验证基线

- 实时库：近 7 天完成 21 条（action_feedback 仅 2 条）；暂停与冻结 229 条；62 个 goal 全停滞；panorama_attempts 21 条 0 成功；reminder_links missing 6；knowledge_reviews failed 2、frozen 10。

## 结果（2026-11-17 凌晨）

- 三单元合并：`work/m26-k`（本周完成与回顾收口）、`work/m26-l`（全景注意力、错误中文化、忽略与停止处理、Spotlight 路由、提醒深链、每周回顾菜单）、`work/m26-m`（恢复冻结委托、包版本文案、Spotlight contentURL、授权状态、AppShortcutsProvider），集成修复一处测试对齐。
- `swift build -j 2` 53.8 秒通过；`swift test -j 2` 420 项 0 失败 22.1 秒（418 基础上新增 2：恢复冻结与版本文案；另改一处既有测试：迁移包恢复后 queued 委托变为 failed 且不再自动续跑）。
- 回顾：本周完成 21 条全量可见（完成日期 + 来源），暂停段收窄到 workspacePausedTasks（229 条冻结历史噪声退出），停滞目标接逐个澄清与行尾加下一步，全部行标题去标签。
- 注意力：全景 failed/unknown 并入 workspaceNeedsAttention，处理页新段带重试；限制：PanoramaScreenModel 只暴露当前一次尝试状态，聚合的是当前失败而非历史计数（如需计数要给 store 加读取接口，留待后续）。
- 处理页：错误三类中文映射；失败项可忽略（UserDefaults `voiceos.processing.ignoredFailures.v1`）或停止处理（复用既有 cancel）；「已全部处理」清空态。
- 恢复语义：queued/running 的 assistant_executions 冻结为 failed（迁移前委托尚未完成，可手动重试）；包版本过新有专门文案。
- 未做：界面截图仍受锁屏阻断（回顾新段、处理页新段与清空态、设置页提醒深链按钮），解锁后补拍。
