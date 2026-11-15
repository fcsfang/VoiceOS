# 待办与问题与目标的成熟模型对照

研究日期 2026-11-15。三份实测报告：`work/tasks/20261115-action-model-study/A1-gtd.md`（GTD、OmniFocus、Things）、`A2-tasks.md`（Todoist、Linear、Notion、Apple Reminders）、`A3-knowledge.md`（Obsidian、Logseq、Zettelkasten、SiYuan、Andy Matuschak 的问题队列）。每个结论在对应报告里带官方文档 URL 与原文摘句。

## 三家模型的一致形状

1. **结果与动作是两种东西，且结果承载动作。** GTD 用项目清单与行动清单两张平行清单加引用；OmniFocus 用容器（项目 → 行动）；Things 用区域 → 项目 → 待办三级。没有一个产品把两者压成一个 `kind` 字段。
2. **结果可以完成或放弃。** OmniFocus 项目有 Active、On Hold、Completed、Dropped 四态；Things 项目可完成；GTD 项目完成离开清单。VoiceOS 的 opportunity 没有完成态，是三家里的异类。
3. **停滞会被主动抓出来。** OmniFocus 的「停滞」是可查询谓词：活跃项目且无剩余行动，可保存为自定义透视，Review 按项目回顾日期排队。GTD 靠周回顾逐项检查。Things 没有文档化检测，但用项目内待办与「只规划最近 1 到 3 步」的建议降低脱钩概率。
4. **将来也许有独立位置和回看节奏。** GTD 的 Someday/Maybe、OmniFocus 的 On Hold 与 Defer、Things 的 Someday（每两个月回看）。它不等于垃圾，也不等于目标。
5. **问题不是一等公民。** 四款任务产品都没有「问题」对象：Todoist 用不可完成任务加评论，Linear 用 Triage 状态加可 resolve 线程，Notion 用页面属性，Apple Reminders 里一切皆 reminder。知识工具把问题表示为笔记加类型属性，靠回看入口与转化出口承载（Matuschak 的问题队列：每天少量浮现，成熟后转成永久笔记）。
6. **澄清结果放在状态上，对象类型保持稳定。** Linear Triage 把未澄清项放进工作流之外的状态类别，接受、拒绝、稍后都只改状态，不改对象类型。

## VoiceOS 的差距

| 机制 | 成熟产品 | VoiceOS 现状 |
| --- | --- | --- |
| 结果承载多个动作 | 项目容器 | 无父子关系，task 与 opportunity 同表并列 |
| 结果可完成或放弃 | 四态项目 | opportunity 不可完成 |
| 停滞可查询 | 活跃结果零开放子项 | 无法表达 |
| 将来也许独立 | Someday / On Hold | 混进 opportunity |
| 澄清放状态 | Triage 状态类别 | 澄清与提升都改 kind，原对象消失 |
| 回顾覆盖结果 | 项目回顾日期 | 每日回顾只认 task |

## 决定

1. **目标保留，动作挂上去。** 给 `actions` 加 `parent_id`：目标是容器（kind 继续用 opportunity 承载目标语义），下一步动作是挂在目标下的 task。提升不再消耗目标本身；「转为待办」改为「添加下一步」，目标保留。
2. **目标可完成或放弃。** 目标获得完成态（达成）与放弃态（不再跟进），两者都保留历史。
3. **停滞可见。** 新增查询「活跃目标且零个开放子项」，进每周回顾与问题与目标页顶部提示。这是 OmniFocus 停滞透视的最小复刻。
4. **将来也许独立。** 目标增加 `someday` 状态与回看节奏（每两个月），不再与目标混装。
5. **问题不建对象。** 问题用目标的意图类型（`ActionIntentMetadata.intentType` 已有）承载；需要提醒时，给目标加一条下一步动作，提醒落在动作上，与 Apple 提醒事项的承载单位一致。
6. **存量 197 条机会分批澄清。** 不自动迁移。目标页提供批量视图：达成、放弃、将来也许、加下一步四个出口，由用户逐条决定。

## 与既有实现的关系

- `promoteAction`（P1，`ActionStore.swift:170`）是过渡手段：它把目标本身改成任务，短期解决可见性，长期应被「添加下一步」取代。迁移完成后删除或降级为「直接达成」。
- 「转为待办」入口（P2）保留，文案改为「添加下一步」，行为改为创建子任务而不是改 kind。
- 撤销、包格式、外部完成确认都以 task 为门槛，不受目标完成态影响。

## 链接

- A1、A2、A3 报告与 `docs/product/todo-and-questions.md`
