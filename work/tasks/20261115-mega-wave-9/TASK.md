---
status: merge-ready
started: 2026-11-15
updated: 2026-11-15
branch: work/mega-9
owner: coordinator
---

# 并行大波第九批（复核修复）

## 目标

按第三轮只读复核的清单修复。R5 产品复核 10 条，R4 代码复核另计。基线 `main` 为 `63fdb30`，299 项测试。

## 单元

### N1 提醒设置与意图

文件：`Sources/VoiceOSApp/VoiceOSApp.swift`、`Sources/VoiceOSApp/ReminderSettingsView.swift`、`Sources/VoiceOSApp/AppIntents.swift`、`Sources/VoiceOSCore/ReminderFields.swift`、`Tests/VoiceOSCoreTests/ReminderDefaultAlertChecks.swift` 追加。

- 关闭「具体时刻」时清空旧时刻与旧通知，按默认 09:00 保存并显示真实回读时间；无日期但有通知时 `validate()` 拒绝「通知需要安排日期」。
- 关闭「发送通知」且已有非默认通知时先确认，再清空。
- `saveReminderSettings` 所有失败分支写具体 status，视图错误区不复用成功文案。
- 意图：`OpenTodayActionsIntent` 标题与描述改「打开行动列表」、dialog 同步；未就绪文案区分「资料库未就绪」与「当前不能开始口述」。
- 测试：validate 无日期通知拒绝；默认通知路径不受影响。

### N2 双语、核对、周回顾与快捷键清单

文件：`Sources/VoiceOSApp/BilingualView.swift`、`Sources/VoiceOSCore/Bilingual.swift`、`Sources/VoiceOSApp/WorkspaceSourceView.swift`、`Sources/VoiceOSApp/ReverifyControls.swift`、`Sources/VoiceOSApp/WorkspaceProcessingView.swift`、`Sources/VoiceOSApp/WeeklyReviewView.swift`、`Sources/VoiceOSApp/WorkspaceView.swift`、`Sources/VoiceOSApp/Onboarding.swift`。

- 译文对照：生成前显示模型名、段数与字数与「发送到云端模型，可能产生费用」；仅本机与未校正两态提供动作按钮（允许云端处理 / 去更正转写）；截断后提供「继续下一批」并按批次推进；缺失段可单独重试。
- 重新核对：恢复成功的行移出「需要重新核对的原件」计数与列表，收进「本次已恢复」折叠组；交叉引用改为不依赖按钮名的说法。
- 每周回顾：撤销提示只在页首出现一次；同屏重复的今天/逾期列表去重（保留今天收尾，另一处只留计数与入口）。
- 快捷键清单：设置页与引导补 ⌘I、⌘[，标注作用域（全局 / 仅主窗口 / 列表聚焦）与撤销仅当前会话。
- 测试：Bilingual 批次推进纯函数（若新增）。

## 验证

- 单次 `swift build -j 2`，修完错误后单次 `swift test -j 2`。
- 实机不可得时写明（锁屏）。

## 结果

2026-11-15 三个修复单元集成到 `work/mega-9`：N1 `b18bf83`，N2 `ac40260`，N3 `248b0e5`、`0ea2fe7`；协调者补回读字段放宽与测试 awa​it 位置修正。

`swift build -j 2` 通过；`swift test -j 2` 307 项 0 失败（新增 8 项：无日期通知拒绝、撤销级联带非空备注、完成往返版本化命令号、提醒恢复幂等、冻结后继等）。

R5 产品十条全部处理：双语发送预览与分批、受阻态出口、核对已恢复分组、周回顾去重与单处提示、快捷键清单补全、意图文案对齐。R4 代码复核修复前六条：撤销判定按备注比对、完成命令号带版本、外部完成后继幂等恢复与失败保链、冻结后继 validity 跟随源、回收站撤销文案如实。R4 剩余六条（字段不一致状态、地点 proximity 与坐标、构建脚本原子性、基线脚本护栏、口述四态、译文编号校验、全景语义校验）留到第十批。

## 链接

- 第五到第八批任务卡；R5 产品复核报告
