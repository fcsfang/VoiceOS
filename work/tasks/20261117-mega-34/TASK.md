# 并行波 34：注意力入口与计数、启动结果就位、疑点前置、刷新热路径三刀

来源：只读发现者 A（使用逻辑与信息呈现）与 C（刷新热路径）。发现者 B（真实数据积压）稍后并入，其新点留待波 35 或追加单元。

## 完成判据

1. 侧栏注意点在存在转写疑点、跟进失败、知识核查失败时点亮，显示合计计数「有 N 项需要查看」，点击打开处理情况；排队与运行中的工作不计入；无注意点时完全隐藏。
2. 行动·全部页不再重复显示专注任务（「我的待办」列表排除专注段的 id），计数一致；「我的待办」页行为不变。
3. 启动页生成成功：自动选中新生成记录，结果包渲染在输入区之下、历史之上，并滚动到可见；captureOnly / clarify / 正常三类路由的状态文案不变。
4. 材料详情：存在未解决疑点时，标题状态行下常显疑点块（条数 + 逐条回听/跳原文），底部折叠组保留历史与原文版本；无疑点时无块。
5. 刷新热路径：a) recordingFollowupValidities 复用快照的 latest 映射（新形参默认 nil 回退现读）；b) assistant 已发布数组无 queued/running 时 processNext 与 discover 短路，reload 复用快照校验上下文；c) ConversationStore 的 conversations() 与 conversationsForSource 改单条 JOIN 批量查询，解码结果一致。
6. 合并后 `swift build -j 2` 与 `swift test -j 2` 一次通过（444 项基础上新增）。

## 共享契约

- 计数公式（H1）：`workspaceAttentionCount` = 疑点条数合计 + 失败跟进份数 + 失败知识核查份数 + (workspaceNeedsAttention ? 1 : 0)；不含 queued/running。注意点组件已存在（WorkspaceAttentionDot），只改条件、计数与文案；`workspaceNeedsAttention` 本身不动。
- K1 只改 VoiceOSCore 与 VoiceOSApp.swift 与测试；不新增界面调用的懒加载方法（懒加载迁移与刷新作用域留给与 C1 同波的设计）。
- 启动页选中（I1）：仅用 TaskInitiationView 本地 `selectedID`；不改 VoiceOSApp 生成函数签名与返回类型。
- 疑点块（J1）：复用现有 unresolved_issues 行控件与 playUnresolvedIssue/jumpToOriginal，不新建数据通道。
- latest 形参（K1）：`recordingFollowupValidities` 增加 `latest: [String: [String]]?`（sourceID 到当前 claim id 集）或等价签名，nil 时保持今天行为。
- 本轮无 schema 迁移。

## 单元与文件所有权

| 单元 | 分支 / 目录 | 独占文件 | 内容 |
|---|---|---|---|
| H1 注意力与行动列表 | `work/m34-h1` / `.worktrees/m34-h1` | `Sources/VoiceOSApp/WorkspaceView.swift`、`Sources/VoiceOSApp/WorkspaceProcessingView.swift` | 判据 1、2 |
| I1 启动结果就位 | `work/m34-i1` / `.worktrees/m34-i1` | `Sources/VoiceOSApp/TaskInitiationView.swift` | 判据 3 |
| J1 疑点前置 | `work/m34-j1` / `.worktrees/m34-j1` | `Sources/VoiceOSApp/WorkspaceSourceView.swift` | 判据 4 |
| K1 刷新热路径 | `work/m34-k1` / `.worktrees/m34-k1` | `Sources/VoiceOSApp/VoiceOSApp.swift`、`Sources/VoiceOSCore/RecordingFollowup.swift`、`Sources/VoiceOSCore/AssistantExecution.swift`、`Sources/VoiceOSCore/ConversationStore.swift`、`Sources/VoiceOSCore/WorkspaceSnapshot.swift`、`Tests/VoiceOSCoreTests/` | 判据 5 |

规则同前：只在所属工作树改文件，不跑构建与测试，不碰主检出与实时库，提交到自己的分支，提交信息结尾固定一行 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 决策细节

- H1：新增 `workspaceAttentionCount` 计算属性在 WorkspaceProcessingView 的 ControlCenter 扩展内；注意点文案「有 N 项需要查看」，accessibilityLabel 同步；行动全部页过滤用 focusedActions 的 id 集合，专注段本身保留。
- I1：`generate()` 成功后以已知集差找新记录设 `selectedID`；版面顺序 composer → package(selected) → history；ScrollViewReader 滚动到 package。注意 onAppear/onChange 的 artifactDraft 同步逻辑保持。
- J1：把底部折叠组里的 unresolved_issues 渲染抽成子视图（含条数、回听、跳原文），标题状态行下常显；折叠组继续保留全部内容与原文版本入口。
- K1：assistant 短路条件 = 已发布数组无 queued/running（processNext 与 discover 两个入口都在入口处判）；reload 把 `.assistant` 快照的校验上下文复用给 resume 路径；conversations 单条 JOIN 取全字段、conversationsForSource 同法；解析复用现有行解码器，保持 JSON 字段语义一致。测试覆盖：latest 形参复用与回退、无排队时短路、批量会话与逐条结果一致。

## 验证基线

- 实时库（只读）：疑点 239 条 / 26 份、失败跟进与知识核查失败若干（以发现者 B 的核实为准）。
- 用户在场：界面实拍与重启推迟到空闲窗口；dist 构建完成后如未空闲，重启延后并在 STATUS 记录。

## 结果（完成后填）

## 追加：发现者 B 与单元 L1（搜索首查）

实时证据（2026-11-17 上午，只读）：`search_index` 0 行、meta dirty=1、应用运行中；`MATCH '工作'` 返回 0。索引文本约 36 万字符。首查按空索引返回，UI 不重查。

批量校正后的积压（留待后续波次）：
- 完成且无当前版本结果 78 条（最老 32 天）；提醒事项已完成待登记 25 条（24 条在暂停候选）；暂停待办约 30 条；知识核查 issues 69 条/16 份；followup 43 行 51.9MB 字符、最大行 6.2MB；主题覆盖 30/80；panorama 22 次 0 完成（失败原因以进程退出与依据变化为主）。

L1 单元（追加进本波）：
- 文件：`Sources/VoiceOSCore/SearchIndex.swift`、`Tests/VoiceOSCoreTests/SearchIndexChecks.swift`（独占）。
- 判据 7：搜索路径遇索引脏或为空时同步重建后查询，首查即命中；空闲单飞重建保留为过期刷新；重建失败不静默吞错（错误可观察）。

## 结果（2026-11-17 中午）

- 五单元合并：H1 注意力与行动列表（注意点计数、全部页待办去重）、I1 启动结果就位（选中新记录、结果包前置、滚动）、J1 疑点前置（标题下常显疑点块，折叠组保留历史）、K1 刷新热路径三刀（validity 复用快照 latest、assistant 空闲短路与校验上下文复用、会话列表单条 JOIN 批量；三组测试）、L1 搜索首查（脏索引同步重建后查询、失败不静默、5 项测试）。
- 集成修正：TopicSearchIndexChecks 两条旧语义对齐首查即命中。H1 自报计数在疑点与 needsAttention 并存时可能双计，按契约原样保留，口径留待波 35 复核。
- swift build -j 2 通过；swift test -j 2 453 项 0 失败（444 基础上新增 9）。
- 隔离副本（306MB 实时库快照，索引 0 行 dirty=1）：首查「工作」命中材料 22 / 主题 1 / 观点 127 / 行动 69，索引重建 1686 行；侧栏「有 204 项需要查看」；材料详情「疑点 6 · 核对未完成」逐条回听与跳原文。启动页生成路径因隔离实例未配模型未实机重放，行为由代码审查与本地选中逻辑确认。
- 发现者 B 校正的积压进入波 35 候选：完成无结果 78、提醒已完成待登记 25、暂停待办约 30、知识核查 issues 69 条/16 份、followup 51.9MB、主题覆盖 30/80、panorama 22 次 0 完成。
