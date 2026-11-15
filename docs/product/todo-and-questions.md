# 待办与问题与目标的关系

## 现状（代码事实）

两者是同一张 `actions` 表的两种 `kind`：

- `task` 待办：承诺的下一步行动。可被安排今天、可同步 Apple 提醒事项、可标记完成（`ActionStore.swift:108` 只允许 task 完成）。
- `opportunity` 问题与目标：尚未承诺的开放问题。不能完成，不可安排提醒，页面文案是「不计为已承诺待办」。
- `ai_suggestion` AI 建议：同上，归属 AI。

从待办澄清到问题与目标是一次性动作（`clarifyAction`，`ActionStore.swift:129`），反方向没有入口。提醒事项同步、每日回顾、外部完成确认全部以 `kind == task && state == open && validity == current` 为门槛（`ActionScheduleStore.swift:50,106`、`DailyReview.swift:16`、`ExternalActionCompletion.swift:14`）。

## 产品逻辑

两者不是同一层级的分类，而是同一件事的两个状态：

- 问题与目标是「张力」：还没决定要不要做、怎么做，需要被保留和回看。
- 待办是「承诺」：已经决定要做，需要被提醒、被完成。

用户每天看的是 Apple 提醒事项，它只认承诺。所以「需要被提醒的问题」必须能进入待办，否则它在提醒事项里不存在。

## 决定

1. 增加反向通道「转为待办」：问题与目标可以一键提升为待办，提升后进入我的待办，并立即获得提醒事项与安排今天的能力。
2. 不做自动提升。一个问题是否需要被提醒是用户的判断，系统只提供通道，不替用户承诺。
3. 不合并两个概念。「问题与目标」保留为尚未承诺的池子，页面继续显示「不计为已承诺待办」。
4. 幂等：提升命令以 `action_revisions.command_id`（已有唯一约束）为回执，重复执行返回同一版本，不需要新表。

## 实现

- `ActionStore.promoteAction(actionID:expectedVersion:commandID:)`：写入 `promote:` 前缀的修订（state 不变、note「转为待办」），把 `kind` 改为 `task`、`intent_actor` 改为 `user`，版本加一。
- `validateStoredActions` 接受提升修订（与澄清修订同一形状）。
- 行动页「问题与目标」行与行动详情页提供「转为待办」；成功后提示「已转为待办」。
- 测试覆盖：幂等回执、版本链、非 opportunity 或非 open 拒绝、包往返校验。

## 未做与理由

- 不在提升时同时挑日期。日期与提醒留在既有「安排今天 / 提醒事项」流程里，避免两步合成一步后无法撤销。
- 撤销栈（⌥⌘Z）暂不覆盖 kind 变化，状态撤销与类型提升是两件事。

## 链接

- `Sources/VoiceOSCore/ActionStore.swift`
- `Sources/VoiceOSCore/ActionScheduleStore.swift`
- `docs/product/reference-products.md` 第 47 行（GTD 澄清）
