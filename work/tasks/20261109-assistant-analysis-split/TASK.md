---
status: review
started: 2026-11-09
updated: 2026-11-09
branch: work/assistant-analysis-split
pr: -
owner: coordinator
---
# AI 助理按任务类型分流：执行类只提醒，思想类直接分析

## 目标

用户反馈 AI 助理从未帮他处理过任何事，也从未对他的问题解惑。实时库证据：76 次助理评估全部判定「没有明确委托」，唯一一次代办的执行因依据变化失败；讨论链路从未产生过一轮个人发言。用户给出的方向是，执行类任务交给 Codex 这类代理、VoiceOS 只负责提醒；思想类的任务和问题由 VoiceOS 直接分析和解惑。

## 数据形状

- `AssistantIntent`：`analysis | execution | reminder | none`，每条任务/问题一个判断。
- `AssistantMode`：执行记录的形态，`execution` 走原有代办，`analysis` 走直接分析；写进 `assistant_executions.input_json`，旧记录缺省为 `execution`。
- 评估解码容忍旧格式与缺字段：有 `intent` 用 `intent`，否则由 `explicitDelegation` 推出；缺 `kind` 记为 `draft`，缺 `supported` 记为 false，避免整批「数据缺失」失败。

## 范围

- 自动发现只评估当前有效的开放待办；`analysis` 自动排队分析，`reminder`/`none` 不执行，`execution` 保持原有明确委托路径。
- 「问题与目标」新增「让 VoiceOS 分析」入口，一次点击直接分析，不再要求先明确委托；分析直接执行，不再调用分类器。
- 分析提示词要求直接分析想法与问题、保留否定与条件、不列计划、不声称执行外部动作；分析交付不要求检索引用。
- 提醒路径不变：待办仍同步 Apple 提醒事项。

## 非目标

- 不自动分析 151 条历史「问题与目标」，避免一次产生上百次模型调用；问题按需点击分析。
- 不修改观点归属或任务完成状态。

## 验证

`swift build -j 4`；`swift test -j 4` 70 项 0 失败。新增 3 项测试：思想任务自动分析、执行类不排队且解码兼容旧格式、问题按需分析且不调用分类器。实机核对等解锁后在副本上补做。

## 进展

- 2026-11-09 核心与入口完成：意图分类、分析模式、自动分析与按需分析、标签区分。
