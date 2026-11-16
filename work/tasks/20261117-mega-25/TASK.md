# 并行波 25：刷新性能、备份可见、搜索核心

来源：性能专项 9 点与搜索设置专项 9 点（两路只读发现），按影响除以成本取。每次交互后的 reload 串行约 3 秒，其中约 0.7 到 1 秒是两处可省的重复读；备份只有文件没有入口；搜索两类硬伤（固定 60 条按类截断、中文两字词退化为全表 LIKE 且丢排序）与索引在首键路径重建。

## 完成判据

1. 跟进有效性校验接受应用层预载数组：`recordingFollowupValidities` 的带预载重载可被应用目标调用，reload 调用点传本轮已发布的记录/认识/行动数组，`validity.*` 段耗时从约 0.4 秒降到近零（以 trace 标记 `validity.reused` 出现为证）。
2. 助理校验上下文在一次校验或发现循环内只构建一次：`assistantInput`/`assistantExecutions` 的循环调用共享一个 `AssistantValidationContext`，不再每个任务重建三张全表。
3. reload 里首屏之后不再有无条件 200ms 睡眠（首屏前的节奏保留不影响）。
4. 备份：每日最多一次；备份目录用 APFS clonefile（`clonefile` 或 `cp -c` 语义）替代逐字节复制；设置页备份行显示「最近备份 时间 · 共 N 份」并加「在访达中显示」。
5. 搜索核心：两字中文 token 不再把整条查询退化为 LIKE；长 token 走 FTS、短 token 作过滤，合并后按相关度排序。搜索 API 支持每类上限并返回各类计数。索引重建离开按键路径：写路径只置脏，重建在空闲/异步执行；触发器只对标题与转写相关列置脏。
6. 搜索界面：每类最多 20 条，分组标题带计数；标题与摘要命中词高亮；空态显示最近 8 条搜索胶囊。
7. 合并后 `swift build -j 2` 与 `swift test -j 2` 一次通过（409 项基础上新增）。

## 共享契约

- 搜索 API：`searchAll(query, perKindLimit:)` 返回按类数组与各类总数（核心 I 定义，应用 G 消费）。语义：每类最多 perKindLimit 条，排序相关度优先、30 天内编辑的记录加小权重；短 token 仅作过滤不参与 bm25。
- 索引维护：`rebuildSearchIndexIfNeeded` 保留为写路径之外的维护函数；查询若发现脏，先按既有索引返回，再异步触发重建（同进程内单飞）。
- 备份：`DatabaseBackup` 暴露 `lastBackupDate` 与 `backupCount`（或等价），设置行消费；clonefile 失败时回退既有复制实现。
- 预载重载公开：`recordingFollowupValidities(_:catalogRows:claimRows:actionRows:)` 改为 `public`，签名不变。

## 单元与文件所有权

| 单元 | 分支 / 目录 | 独占文件 | 内容 |
|---|---|---|---|
| F 核心性能 | `work/m25-f` / `.worktrees/m25-f` | `AssistantExecution.swift`、`RecordingFollowup.swift` 与其测试 | 判据 1、2 |
| G 应用接线与设置 | `work/m25-g` / `.worktrees/m25-g` | `VoiceOSApp.swift`、`WorkspaceView.swift`、`SearchControls.swift`、`DatabaseBackup.swift` | 判据 3、4、6 |
| I 搜索核心 | `work/m25-i` / `.worktrees/m25-i` | `SearchIndex.swift`、`Database.swift`（仅触发器段）与其测试 | 判据 5 |

规则同前：只在所属工作树改文件，不跑构建与测试，不碰主检出与实时库，提交到自己的分支，提交信息结尾固定一行 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## 决策细节

- F：循环共享用现有的 `context: inout AssistantValidationContext` 重载；发现循环里请把 context 提到循环外，冻结失效时重建一次。测试断言行为（同一批任务在 context 构建次数受限时结果一致），不测私有计数。
- G：reload 段里 `records/claims/actionRecords` 在调用点前已可用，直接传；睡眠删除前确认它服务的唯一目的是让出一帧，若确属有意让帧，改成仅首屏路径保留并在提交信息里说明。备份行的计数来自目录枚举，时间取最新文件修改时间；「在访达中显示」用 NSWorkspace。搜索高亮只对标题与摘要，保持文本可选。
- I：短 token 上限与过滤方式自己定，要求是中文两字词有相关度排序且不全表扫描转写文本；FTS 查询仍防注入式拼接（沿用参数绑定或安全转义）。触发器收窄前先列表当前所有置脏列，跟进回执、呈现 JSON、策略切换的写入不再置脏。

## 验证基线

- 实时库：79 材料、1052 认识、524 行动、备份 7 份共约 1.9GB、库 291MB。
- 波 24 刚合并（PR #196），reload 段 trace 标记与调用点以当前 main 为准。
