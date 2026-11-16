# 并行波 23：问题与目标三分与问题优先回答

用户决策（2026-11-16）：问题的默认归宿是「VoiceOS 先回答」；录音中活动这类旁白直接移出问题池；界面上的「问题」和「目标」分成两个入口。

## 完成判据

1. 数据层有 `nature`（question / goal / narration / unknown），迁移 64 回填存量：标题含【录音中活动】→ narration；【问题】或问号 → question；【长期目标】→ goal；其余 unknown。
2. 行动页的「问题与目标」拆成「问题」「目标」两个入口。问题入口只列 nature=question；目标入口只列 nature=goal，unknown 以折叠的「系统整理的建议」区块出现在目标页，narration 不出现在任何列表。
3. 问题详情页以「问题 + VoiceOS 的回答」为顶点。预计时长、子任务、任务说明、下一步（无子项时）在问题页隐藏；「记录进展」不再展开在依据区底部，而是顶部操作之一（任务页）或隐藏（问题页，用回答与追问代替）。
4. 澄清队列按入口类型给出口：问题给「让 VoiceOS 试答 / 想清楚了 / 加下一步 / 以后再说」；目标给「留作目标 / 将来也许 / 不是我要做的事 / 加下一步」；unknown 给「归为问题 / 归为目标 / 是旁白」。
5. 合并后 `swift build -j 2` 与 `swift test -j 2` 一次通过（392 项基础上新增测试）。
6. 隔离副本实机验证：迁移 64 后问题 43、目标 62、旁白 57、未归类 35；两个入口与问题详情页截图；澄清队列按类型出口可用。

## 共享 API（U1 实现，其他单元按此编码）

```swift
public enum ActionNature: String, Codable, Sendable, CaseIterable {
    case question, goal, narration, unknown
}
// ActionRecord 增加：public let nature: String（列名 nature，缺省 unknown）

extension VoiceOSStore {
    /// 修订账本 note 前缀「归类：」，命令号 "nature:<commandID>"，幂等。
    public func setActionNature(id: String, expectedVersion: Int, nature: ActionNature, commandID: String = UUID().uuidString) throws -> Int
    public func openQuestions() throws -> [ActionRecord]      // kind='opportunity', nature='question', state='open', validity='current'
    public func openGoals() throws -> [ActionRecord]          // nature='goal' 同上
    public func untriagedSuggestions() throws -> [ActionRecord] // nature='unknown' 同上
}
```

`stalledOutcomes()` 只统计 nature='goal'。抽取写入动作时按 proposal.contentKind 或标题标签落 nature；包导出与恢复必须带上 nature，旧包恢复为 unknown，包格式号不变。

## 单元与文件所有权

| 单元 | 分支 / 目录 | 独占文件 | 内容 |
|---|---|---|---|
| U1 核心 | `work/m23-a` / `.worktrees/m23-a` | `Database.swift`、`ActionStore.swift`、`CognitiveStore.swift`（仅抽取插入）、`PortablePackage.swift`、`TestSchema.swift`、新增 `ActionNature.swift` 与测试 | 迁移 64、API、回填、校验、包往返、stalled 收窄 |
| U2 列表分流 | `work/m23-b` / `.worktrees/m23-b` | `WorkspaceView.swift`、`SavedViews.swift`、`ActionRowStatus.swift` 与其测试 | 两个入口、未知建议区块、行状态、全部页预览、澄清入口带上范围 |
| U3 问题详情 | `work/m23-c` / `.worktrees/m23-c` | `WorkspaceActivityViews.swift`（含新增回答区块） | 顶点换答案、出口按钮、隐藏任务槽、记录动作上移 |
| U4 澄清与回答 | `work/m23-d` / `.worktrees/m23-d` | `ActionClarifyQueueView.swift`、`VoiceOSApp.swift` | 队列按类型出口、试答入队、归类动作接线 |

规则同波 22：只在所属工作树改文件，不跑构建与测试，不碰主检出与实时库，提交到自己的分支，提交信息带署名行。U2 的澄清入口传 `scope`（questions / goals），U4 的队列视图接这个参数；未知建议只出现在目标页的折叠区块，行内提供归类菜单。

## 决策细节

- 问题行：图标为问号，状态槽显示「未回答 / 回答中 / 已回答」（按该 action 的最新分析执行），来源第二行。点击进详情。
- 问题详情的回答区块：读取该 action 的 assistant 执行（mode analysis）。无记录时按钮「让 VoiceOS 回答」；运行中显示进度；完成显示结果摘要与「阅读结果」；失败显示原因与重试。模型未配置时禁用并说明。
- 问题出口：「想清楚了」= completeOutcome；「这件事我自己做」= 现有添加下一步表单；「以后再说」= someday；「放下」= dismissed；「继续思考」= 现有讨论。任务与目标详情保持现状。
- 目标页顶部停滞横幅只统计 goal，文案数字随之变化。
- 「全部」页的问题与目标预览拆成两组各至多 3 条，各带「查看全部」跳到对应入口。
- SavedViews 里旧的「问题与目标」筛选名做兼容：读取时映射为「问题」，保存新视图只写「问题」或「目标」。

## 验证基线（实时库只读）

- 存量：197 = 长期目标 62 + 录音中活动 57 + 问题 43 + 其他陈述 24 + 想法观点 11。
- 全部 197 条从无修订、无讨论、无 AI 分析；stalled 横幅现为 197，迁移后目标入口应为 62。

## 结果（2026-11-17 凌晨）

- 四单元合并：`work/m23-a`（nature 与迁移 64）、`work/m23-b`（两个入口）、`work/m23-c`（问题详情顶点）、`work/m23-d`（澄清队列分型），集成修复 `cd79edb`。
- 集成对齐三处：U2 期望的 `ActionClarifyScope` 统一为 U4 的 `ClarifyQueueScope`；归类失败回写 `self.error`（catch 绑定遮蔽）；重复任务后继行动继承 nature。测试侧：种子按抽取派生归类不再重复归类，裸删行动前先删修订行（外键）。
- 构建 `swift build -j 2` 一次通过 61.5 秒；`swift test -j 2` 405 项 0 失败 20.9 秒（392 基础上新增 13 项：ActionNature 5、问题行状态 5、澄清分型 3）。
- 隔离副本（DB `.backup` + assets `cp -Rc`）迁移 63→64 精确达标：user_version 64；goal 62、narration 57、question 43、unknown 35，共 197 条，与基线一致。
- 实机截图（/tmp）：`v23-actions.png`（新标签组）、`v23-questions.png`（43 条问题，问号图标与未回答状态槽）、`v23-goals.png`（62 条目标，停滞横幅同步降到 62）、`v23-tail2.png` 与 `v23-untriaged.png`（系统整理的建议 35 条折叠区块，展开后每条带归类菜单）、`v23-question-detail2.png`（问题详情以「VoiceOS 的回答」为顶点，任务槽全部隐藏，出口为想清楚了/让 VoiceOS 回答/继续思考/这件事我自己做/以后再说/放下）、`v23-clarify-q.png`（问题范围队列：让 VoiceOS 试答/想清楚了/以后再说/跳过，剩余 43 条）。
- 遗留小项：问题详情的回答区块与动作行各有一个「让 VoiceOS 回答」按钮，重复；记入波 24 候选。
