---
status: in_progress
started: 2026-11-15
updated: 2026-11-15
branch: work/mega-16
owner: coordinator
---

# 问题与目标转为待办

## 目标

用户指出「问题与目标」里有需要被提醒才能解决的事，但提醒事项只认待办，导致这些问题不可见。按 `docs/product/todo-and-questions.md` 增加「转为待办」反向通道。基线 `main` 为 `9344182`，333 项测试。

## 单元

### P1 核心提升命令
文件：`Sources/VoiceOSCore/ActionStore.swift`、`Tests/VoiceOSCoreTests/ActionStoreChecks.swift`（或既有行动测试文件）。
- `promoteAction(actionID:expectedVersion:commandID:)`：回执走 `action_revisions.command_id`；守卫 kind == opportunity、state == open、validity == current、version 一致；事务内写修订（state 不变、note「转为待办」、command 前缀 `promote:`）并把 kind 改为 task、intent_actor 改为 user、版本加一；沿用 clarify 的 checkpoint。
- `validateStoredActions` 接受提升修订（与澄清修订同形状），包往返校验通过。
- 测试：幂等（同 command 两次返回同版本）、版本链、拒绝（已是 task、非 open、版本过期）、提升后可走提醒调度资格判定。

### P2 界面入口
文件：`Sources/VoiceOSApp/WorkspaceView.swift`（问题与目标区段）、`Sources/VoiceOSApp/WorkspaceActivityViews.swift`（详情页）、`Sources/VoiceOSApp/VoiceOSApp.swift`（ControlCenter API）。
- ControlCenter 增加 `promoteAction` 包装（成功后刷新并返回 Bool）。
- 问题与目标行加「转为待办」操作；详情页对 opportunity 显示「转为待办」按钮；成功后提示「已转为待办」。
- 文案：问题与目标区块副标题与详情页 eyebrow 去掉「不计为已承诺待办」这类系统语，改为「要达到的结果、要弄清的未知；转成待办后可提醒」。
- 不改其他筛选与交互。

## 验证

- 单次 `swift build -j 2`，修完错误后单次 `swift test -j 2`。
- 实机：一条问题与目标转为待办，出现在我的待办，可安排今天。

## 已知边界

- 提升不附带日期选择；撤销栈不覆盖 kind 变化。

## 结果

（待填）

## 链接

- `docs/product/todo-and-questions.md`
