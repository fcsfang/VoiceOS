# ADR034：提醒事项时间观测与三方比较基础

日期：2026-10-13。状态：采用时间回读与纯比较策略；实际排期写入尚未实现。路线 W14，PRD-ACT-02/04、PRD-CTRL-02、AC-15/16。产品权限不变。

## 问题与选择

旧外部快照只有标题、完成状态和标记，无法保留外部改期依据，也无法区分没有期限与从未核对期限。不能在尚无字段基线和操作历史时直接加入自动改期。

备选：①继续只读状态，无法实现 AC-15；②把所有日期都转成设备当前时区的午夜 Date，会混淆整天日期、确切时刻和未知信息；③保留类型化时间观测，先实现可复用三方规则，再接持久意图与执行器。采用③。独立表使旧观测保持原样，也不改写原创建基线。

## 时间语义

- `ReminderDueDate?` 的 nil 是未知/尚未支持；`.none` 是已确认没有期限。旧快照无新增字段时仍解码为 nil，不补写无期限事实。
- `dateOnly(localDate,timeZone?)` 保留 Gregorian 日历日期及原本可用的时区；没有时区的整天日期不猜设备时区，也不转换成 UTC 午夜。
- `instant(utc,timeZone)` 保存规范 UTC 毫秒文本及明确时区。读入规范化后验证，非法日期/时区拒绝；秒和时区不能被省略后悄悄补成承诺。
- 原生连接器只读 `dueDateComponents`。缺年月日、非支持历法、缺时区的有时刻日期、DST 不存在或重复时刻、不能保留的亚秒值保持 unknown。失败不会变成 `.none`。
- Apple 文档明确，不带时分秒的日期组件表示全天提醒，due 组件的时区独立于 start 和父对象时区。因此不借用父对象或当前设备时区推测 due：[dueDateComponents](https://developer.apple.com/documentation/eventkit/ekreminder/duedatecomponents)。对不支持组件保持未知是本轮工程选择，不代表 Apple 完全不能处理这些值。

本轮没有推断“明天”等自然语言。未来提案保存原表达与表达时刻；解析相对日期必须使用那个固定锚点和授权出处，不能用重试时钟。当前 `ReminderScheduleProposal` 只是有界且已解析的内存值，不证明原表达已被准确理解或用户已作承诺。

## 持久与展示

schema33 新增 `reminder_time_observations(id,due_json)`；id 是已有不可变外部观测身份。只有本轮能准确读取的值才保存此行；旧观察保留未知，不回填日期。期限单独变化、或 known/unknown 变化，也生成新外部观测；完全相同回读不重复生成。时间行与观测/完成反馈同事务。

控制中心显示上次回读期限及仅日期/时区含义；unknown 明示“未能核对”，非 linked 沿用上次观测提示。来源、外部标题、完成状态和期限不相互覆盖。含时间行的迁移包 v33 保存历史并校验日期和引用；旧包兼容且恢复仍不携带连接授权。

## 纯三方策略

`ReminderScheduleMerge.decide` 比较 base、remote、desired；输出计划分类，不执行数据库修订或 EventKit 写入。desired 为 nil 是没有本地意图，desired.due=.none 才是明确移除期限意图。规则依据既有[状态机 §5](../architecture/state-machines.md#5-提醒事项三方比较)：

| 条件 | 决策 | 外写 |
|---|---|---|
| 授权失效/依据冻结 | blocked | 无 |
| 身份不唯一或 remote 未知 | unavailable | 无，未知不当无期限 |
| base 未知 | captureRemote | 无，仅候选外部基线 |
| 无本地意图 | unchanged / observeRemote | 无，保留外部变化 |
| desired=remote | unchanged / converged | 无 |
| desired=base，外部变化 | observeRemote | 无，不回写旧值，不改变用户原承诺 |
| remote=base，只有普通 AI 弹性安排变化 | writeFlexible | 只是计划；尚未接执行器 |
| 双方不同变化且普通弹性 | replanKeepingRemote | 无，保留人工字段 |
| 变更涉及明确承诺、人工字段或基线归属不明 | requiresConfirmation | 无 |

不能用新 AI 提案把原用户承诺或人工安排降级为 flexible。字段一致不需要额外审批；重要差异的确认以后必须绑定具体效果，而非依赖一次全局宽泛许可。

## 剩余工作与验收限制

本轮完成时间回读、存储、展示与策略基础，没有实现自然语言期限提取、本地 ScheduleRevision、Operation/outbox、绑定重要变更的确认、EventKit 条件更新或写后核对，也没有修改真实提醒事项。策略的 writeFlexible 不代表已外写。EventKit 无远程原子 CAS，执行器仍须在真正保存前检查作用域/身份/字段并在保存后回读；人工竞态不能靠纯比较算法消除。

W14/AC-15 仍 partial，W16 外部补偿仍待实现。自然案例 A 仍需真实用户行动和后续表达，不能由开发命令生成替代。
