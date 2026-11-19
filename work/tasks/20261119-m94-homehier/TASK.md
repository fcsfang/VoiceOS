# 波 94 任务 C（2026-11-19）：首页「最近」信息层级收敛

## 用户诉求

「打开就能看到材料带来的提醒与帮助。」
首页时间线第一块是「最近想法」卡片流（14 天窗口约 173 张卡），材料分组被推到很深的滚动之后；材料行只有标题、时间与过程状态槽（疑点 N/仅本地/在读），看不到这份材料带来几条待办；无当前观点的材料只提示「这份材料还没有整理出想法」，而真实库里有 8 份材料只剩冻结旧观点，直接点整理会再花一次模型调用并留下又一层历史。

## 改动（Sources/VoiceOSApp/RecentContentHome.swift，行号为改动后）

1. `34-35`：新增 `@AppStorage("voiceos.home.recentThoughts.expanded")`（默认 false）与 `frozenViewpointsItemID`。
2. `101-122` 空态三分支：读取失败分支不变；有材料但无可读内容显示「材料都还没有可读内容」；库内没有符合条件的材料显示「知识库里还没有材料」。
3. `129`：时间线首块改用 `recentThoughtsEntry`；材料日分组紧随其后，成为首屏主体。
4. `225-244` 行尾部：改用 `rowTrailing`，材料行优先显示「N 条待办」（读 `homeSnapshot.digests[item.id].tasks`，随快照构建一次，无逐行扫描）；反馈行仍显示结果待填徽标。
5. `256-274`：原 `statusSlot` 拆成两半。`rowTrailing` 只占价值位；`rowStatusNote` 把「仅本地/整理中/待核对/疑点 N/在读」降为行内次要文字。
6. `284-288`：`rowMeta` 由「时间」变为「时间 · 状态」（有状态时）。
7. `542-553`：新增 `recentThoughtCount`（折叠入口计数）与 `hasAnyMaterial`（与 `RecentContentIndex` 相同的材料过滤：saved/reference_only、origin/speaker=user、非行动反馈）。
8. `560-616`：最近想法收为一条默认折叠的入口按钮（chevron 旋转、`N 条 · 近 14 天`、`.help`、`home.recentThoughts.toggle`）；展开后渲染原分组与卡片，`recent.thought` 标识不变。
9. `618-684` 整理提示：材料有冻结旧观点时文案改为「这份材料上次整理的观点已冻结」，新增「查看旧观点/收起旧观点」（`home.frozenViewpoints.toggle`）与内联旧观点列表（`home.frozenViewpoints`），每条可「看原话」；整理按钮改叫「重新整理这份材料」。
10. `686-698`：`frozenThoughts(_:)` 从 `model.claims`（`WorkspaceSnapshot` 以 `includeFrozen: true` 载入）取 `validity == "frozen"`、`ownership == "user_tentative"`、未被拒绝的旧观点，按引用命中材料，按陈述去重、新者在前。

## 判据落点

- 首屏：折叠入口为一行头部，材料分组紧随其后；展开能力与计数保留，折叠状态持久化在 UserDefaults。
- 价值位：材料行尾部先显示待办数；疑点/仅本地/整理中/待核对/在读进 meta 行。
- 冻结观点：只改文案与入口，不覆盖历史；重新整理仍走原 `reidentify` 路径。
- 行为、标识、键盘：`recent.item`、`recent.thought`、`home.thread`、`home.tasks.list`、`home.organizePrompt` 未改；时间线上下键与回车逻辑未动；新增标识均为附加。
- 无迁移：纯视图层改动；未改数据窗口与快照结构。

## 真实库只读核对

`~/Library/Application Support/VoiceOS/voiceos.sqlite`，`mode=ro`：

- `user_tentative` 冻结观点 323 条，其中被拒绝 0 条。
- 当前观点为 0、冻结观点 >0 的材料 8 份，全部 state=saved、origin/speaker=user。
- 其中 7 份有非空 transcript（42-295 字符），1 份 transcript 为空；8 份均有冻结观点可展示。

## 测试与真实退出码

- `swift build -j 2` → `build_exit=0`（Build complete! 113.65s）
- `swift test -j 2` → `test_exit=0`，Executed 639 tests, with 0 failures (0 unexpected) in 44.887s
- 基线 639 项 0 失败；未改 Core，未新增测试（0 ≤ 3）。
- 构建与测试共用 `/tmp/voiceos-swift-build.lock`；测试结束已 rmdir，锁目录不存在。

## 权衡与遗留风险

- 折叠入口留在顶部而非移到底部：材料从入口下方立即开始，展开入口也保持可发现；与任务书「收进一条默认折叠的入口」一致。
- 冻结观点列表内联展开而非弹窗，避免同一视图再挂第二个 sheet；「看原话」走既有 `openClaim`，引用不可用时沿用原失败提示。
- `frozenThoughts` 在视图层过滤 `model.claims`，仅当前选中且无当前观点的材料触发一次，没有逐行扫描全库；若后续要求快照携带冻结标记，可再迁入 `RecentContentHomeSnapshot`。
- 有冻结观点时仍保留重新整理入口：任务书要求「不再只给」，未禁止；按钮语义改为「重新整理」，文案说明旧观点保留为历史。
- 未在运行中的应用里做视觉核验（约束：不重启应用）；本波只验证真实构建与测试退出码，并做真实库只读核对。
- 8 份冻结材料里 1 份 transcript 为空但仍有旧观点；是否进入首页取决于快照的可读条件（summary/transcript/thoughts 任一非空），未逐条在应用中核验。
