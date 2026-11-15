---
status: in_progress
started: 2026-11-15
updated: 2026-11-15
branch: work/mega-17
owner: coordinator
---

# 结果承载动作模型迁移

## 目标

按 `docs/product/action-model-research.md` 的决定，把「问题与目标」从不可完成的并列 kind 迁移为「结果容器 + 下一步动作」：目标承载下一步（`parent_id`）、目标可完成或放弃、停滞（活跃目标零开放子项）可查询。基线 `main` 为 `93f94aa`，342 项测试。

## 单元

### M1 核心模型
文件：`Sources/VoiceOSCore/Database.swift`（迁移 62）、`Sources/VoiceOSCore/ActionStore.swift`、`Sources/VoiceOSCore/PortablePackage.swift`（如 columns 列表需要）、`Tests/VoiceOSCoreTests/`。
- `actions` 增加 `parent_id`（可空，自引用，指向 kind 为 opportunity 的目标；删除目标时子项置空而不是级联删除）。
- 目标完成：新增 `completeOutcome(actionID:expectedVersion:commandID:)`，允许 kind == opportunity 从 open 变为 completed；放宽 `setActionState` 的完成守卫（只有任务能完成）为「任务能完成；目标走 completeOutcome」；`actions` 的 CHECK 约束随迁移放宽。
- 目标放弃：复用既有 dismissed 状态（`不再跟进`）。
- 停滞查询：`stalledOutcomes()` 返回活跃目标（kind opportunity、state open、validity current）中没有开放子项（parent_id 指向它且 state == open）的集合。
- 子项操作：`attachNextAction(outcomeID:actionID:)` 与 `detach`（置空），守卫：父必须是 opportunity 目标、子必须是 task、不可成环。
- 幂等：所有命令沿用 `action_revisions.command_id` 回执。
- 包往返：parent_id 随 actions 列导出导入；`validateStoredActions` 校验父子（父存在且 kind 为 opportunity、无环）。
- 测试：完成目标、放弃目标、挂下一步与摘除、停滞查询、成环拒绝、包往返、撤销不受影响。

### M2 界面（后续）
目标页与详情页的「添加下一步」、停滞提示、每周回顾区块。本波不做。

## 验证

- 单次 `swift build -j 2`，修完错误后单次 `swift test -j 2`。
- 迁移 61 到 62 在隔离副本上跑通（既有 197 条机会不变，parent 为空）。

## 已知边界

- 不自动迁移存量机会到目标/将来也许；批量澄清界面在后续波次。
- 提升命令保留为过渡手段，M2 后再决定降级。

## 结果

（待填）

## 链接

- `docs/product/action-model-research.md`
