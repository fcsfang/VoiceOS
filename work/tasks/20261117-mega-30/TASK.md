# 并行波 30：任务闭环最后一公里、跟进摘要落库

来源：行动闭环与性能两路发现的剩余高价值项。数据事实：18 条开放待办中 17 条挂了提醒链接，权限拒绝或暂停连接时完成与撤销全被拦住；80 条完成里 79 条来自提醒事项回读、只有 1 条在应用内完成；6 份 completed/current 的 AI 交付静默躺在列表里（最近一份 4 天未读）；followup_json 49.5MB 每次 reload 与 60 秒定时器全量重读并逐行哈希（冷 588ms、暖 184–207ms）。

## 完成判据

1. 提醒事项不可用（权限拒绝、连接暂停、授权失败）时，任务的完成与撤销不被阻断：完成走「仅本地完成（稍后核对）」——写本地修订并挂补偿计划（复用 reminder_compensation_plans 与既有补偿执行器），界面明说「已本地完成，连接恢复前不会同步到提醒事项」；恢复连接后补偿器把完成写入提醒事项。每周回顾里的完成入口同样生效。
2. 列表勾完成后的撤销条加「记一句结果」：打开现有结果记录入口（ActionFeedbackView/任务详情的记录通道），8 秒未点按自动跳过，不影响原有撤销。
3. AI 交付待读可见：行动页头部（或侧栏）显示「AI 交付 N 份待读」（completed 且 validity current 且未标已读，UserDefaults 记 id+updatedAt，键 voiceos.deliveryRead.v1）；交付行显示已读/未读态并置顶未读；交付详情有「已读」按钮；读后计数消失。
4. 跟进摘要落库：sources 增加 followup_digest 列（迁移 65 回填），保存跟进回执时算好写库；读取先取 id+digest，仅失配行读正文；reload 与定时器不再全量重哈希。包格式不变，旧包恢复后按需补算。
5. 合并后 `swift build -j 2` 与 `swift test -j 2` 一次通过（424 项基础上新增）。

## 共享契约

- 本地完成：复用既有本地修订与撤销栈；补偿计划写既有 reminder_compensation_plans（结构自寻）；对已链接任务，尝试直接写提醒事项失败时自动落到本地完成并挂补偿，不新增用户选择弹窗；成功路径行为不变。
- 已读：UserDefaults [executionID: updatedAtISO]；判定 completed && validity current && 记录缺失 → 未读；列表排序「未读在前、其余按 updatedAt 倒序」。
- digest：`followup_digest = SHA256(followup_json)`；读取路径 `SELECT id,followup_json,followup_digest` 后仅对 digest 缺失或失配行做 SHA256 与解码；写入点覆盖保存回执的所有路径。

## 单元与文件所有权

| 单元 | 分支 / 目录 | 独占文件 | 内容 |
|---|---|---|---|
| X 任务闭环 | `work/m30-x` / `.worktrees/m30-x` | `VoiceOSApp.swift`、`WorkspaceView.swift`、`WorkspaceActivityViews.swift` 及其测试 | 判据 1、2、3 |
| Y 跟进摘要落库 | `work/m30-y` / `.worktrees/m30-y` | `Database.swift`、`RecordingFollowup.swift`、`TestSchema.swift`、其测试 | 判据 4 |

规则同前：只在所属工作树改文件，不跑构建与测试，不碰主检出与实时库，提交到自己的分支，提交信息结尾固定一行 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 决策细节

- X：完成路径入口集中在 applyActionState/undoActionChange、每周回顾完成、详情页完成；「仅本地完成」是失败分支的自动落点还是显式按钮由现有错误路径决定（D2#1：提示里给「仅本地完成（稍后核对）」动作）。交付待读的派生存放在 ControlCenter（VoiceOSApp）并从 WorkspaceView/侧栏消费。
- Y：迁移 65 只加列与回填（UPDATE per row 或 SQL 内计算摘要不可行则逐行写，记录耗时）；TestSchema 升 65；读路径改造点：pendingRecordingFollowups / remembered 缓存 / resumeRecordingFollowups 定时器；写点：saveRecordingFollowup 与派生保存路径（自寻）。旧行 digest 为空时回填一次并写库。

## 验证基线

- 实时库：开放待办 18（17 挂链接）、完成 80（79 回读）、交付 6 份 completed/current、followup_json 49.5MB（单行最大 5MB）。
- 锁屏仍在，交互截图待解锁统一补拍。

## 结果（2026-11-17 上午）

- 两单元合并：`work/m30-x`（本地完成通道、记一句结果、交付待读）、`work/m30-y`（跟进摘要落库，迁移 65）。
- `swift build -j 2` 通过；`swift test -j 2` 428 项 0 失败 22.1 秒（424 基础上新增 4：摘要命中/补算/迁移/写入分支；另修 3 处既有测试与幂等细节）。
- 本地完成：提醒不可用（权限拒绝/暂停/写入失败）时完成与撤销回退本地修订，状态文案「已本地完成，连接恢复前不会同步到提醒事项」；补偿走本地持久队列（先落本地、连接恢复后自动冲刷写提醒并回读清除，失败保留），与既有自动回读入口、300 秒计时器、激活唤醒共用触发点。偏差记录：reminder_compensation_plans 只承载到期修正，完成型补偿由队列承担（Core 侧如需入表另行立项）。
- 记一句结果：列表勾选后的 8 秒撤销条新增按钮，打开既有 ActionFeedbackView，不点按自动过期。
- 交付待读：completed 且未标已读计为未读（UserDefaults voiceos.deliveryRead.v1）；侧栏徽标与行动页头部「AI 交付 N 份待读」，未读置顶，详情「标为已读」。
- 摘要落库：迁移 65 加 followup_digest 并回填，写入点唯一（saveRecordingFollowup），读取两段式（命中不读正文不哈希）；实时库实测 89.6MB / 42 行、单行最大 10.3MB，回填预计 0.3–0.6 秒。隔离副本验证：64→65，42/42 回填，79 份来源不变，启动到迁移完成约 2 秒（含启动开销）。
- 未做：界面截图仍受锁屏阻断，解锁后统一补拍。
