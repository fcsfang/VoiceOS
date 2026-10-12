# ADR037：具体效果改期确认与本地期限编辑

日期：2026-10-13。状态：采用。路线 W14；依据 PRD-ACT-02/04、PRD-CTRL-02、P01 的普通自主与重要效果确认边界。接续 [ADR036](036-safe-reminder-schedule-operations.md)，不改变愿景或扩大 M4。

## 问题与选择

普通弹性执行器不能修改用户明确期限、人工期限或归属不明的字段。仅确认“允许 AI 改期”不能说明用户批准了哪个具体效果，旧界面确认也可能在异步等待中被误用于新任务或新日期。

备选：①布尔确认随意图保存，简单但不能绑定外部效果；②每次保存都弹窗，打扰普通任务且不适合后台；③只在重要差异处生成不可变、一次效果许可，执行时复用原有持久操作和回读屏障。采用③。普通弹性仍走持续清单授权，具体确认由用户主动打开，不发聊天提问或无人值守弹窗。

## Core 与界面契约

- `prepareReminderScheduleEffect` 只读生成具体效果，仅用于三方策略 `requiresConfirmation`；显示清单、任务标题、上次回读期限、目标期限、承诺/AI 归属及表达依据。
- 摘要绑定 intent 与输入指纹、link/calendar、observation、授权版本、完整 before 快照及 desired。`confirmReminderSchedule` 必须 actor=user，核对用户实际看到的摘要，仅保存许可，不外写。
- 一 intent 至多一个 grant；命令幂等。效果变化、旧许可撤回或冻结后，须形成新排期版本，不能换命令重批旧意图。
- `executeReminderSchedule(grantID:)` 核对具体效果，在预查询返回、派发、Native 最终保存屏障及写后读取前后重验。仍一 intent 一次外部尝试，unknown 只读恢复。确认不等于成功、完成或认知验证。
- 撤回写不可变 revocation，阻止后续写入。保存后撤回不等于撤销外部效果：保留已派发历史，后续仅回读核对，不自动反向改期。
- 控制中心增加本地期限编辑：仅日期、日期与分钟、明确移除。固定打开时的排期版本/解释时区及首次保存的表达锚点；Core 拒绝不能无损回读的时间（包括 DST 模糊）。保存归属为用户控制中心选择，不伪称来自录音。保存只更新本地 desired，外部差异另行确认。

## 持久化与迁移

schema36 新增 `reminder_schedule_grants`、`reminder_schedule_grant_revocations`，操作可选 `grant_id`。grants 绑定历史 intent/link/observation/access/before/desired，revocations 独立保留原因及命令指纹。校验顺序：意图 → grants → operations。重要操作不能剥离许可后重算摘要绕过验证。

有 grant 的包用 v36；仅普通操作保持 v35，仅意图保持 v34。导入按基础、grants、revocations、operations 顺序，所有恢复意图/许可/操作 frozen；重新连接也不复活旧许可。旧格式不能携带许可表或非空 grant_id。迁移保留历史，不能当作授权恢复。

## 验证与限制

完整 Swift 回归 **527 项、0 failures**；改期专项30项通过，新增13项覆盖批准归属/幂等、显示漂移、错配、移除期限、撤回、await 中冻结、保存后撤回、写前字段变化、事务窗口、v36冻结、许可剥离与非空schema35升级。含BGE的稳定签名构建、严格codesign及差异检查通过。日志与[脱敏证据](../research/evidence/m3-w14-schedule-grants-2026-10-13.json)对应本增量。

没有云端、录音或真实任务修改，未重启用户应用。编译不替代原生UI和真实EventKit改期验收。EventKit无远端原子CAS，确认不证明不存在人工/iCloud竞态。当前字段所有权仍保守：成功回执不自动给予后续自由改期权；语音期限提取仍缺。继续字段所有权/后续弹性重排和W16补偿；M3/AC-15/自然案例A仍partial，不代用户填写自然结果。
