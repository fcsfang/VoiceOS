---
status: started
started: 2026-11-10
updated: 2026-11-10
branch: work/task-initiation
pr:
owner: coordinator
---
# 任务启动（Task Initiation）P0：把模糊口述变成可开始的下一步

## 目标

规格：`VoiceOS_Task_Initiation_Dev_Package/feature-plans/VoiceOS_Task_Initiation_Feature_Spec.md`。VoiceOS 是任务启动层，不是执行者：把口述中的模糊任务、障碍和想法转成四种路线之一，交给 Agent 的可复制提示词、用户自己动手的教程、一个最关键的澄清问题、或仅记录。P0 完成 F-01 到 F-10，验收对应 T01 到 T13。不自动创建任务、不写提醒、不调起任何外部 Agent。

## 仓库审计（2026-11-10）

- 技术栈：SwiftPM macOS 应用，`VoiceOSCore` 领域与 SQLite 存储，`VoiceOSPlatform` 模型端口，`VoiceOSApp` SwiftUI 控制中心，XCTest。构建 `swift build -j 4`，测试 `swift test -j 4`，无 CI。
- 语音/文字入口：录音经转写进入 `sources`/`transcripts`/`transcript_versions`，文字入口 `TextCaptureView` 调 `recordCapturedText`；个人文字走 `recordUserExpression`，外部文字单独归属。每份来源有 `local_only` 与授权版本，云端调用前必须显式放行。
- A 模式：录音与记录页不打断、不追问，理解在保存后进行；没有全局 A/B 开关，安静与否由入口决定。B 模式：`DiscussionView` + `ConversationStore`，用户回合先保存再显式发送，AI 回复与个人原文分开身份。
- 模型调用：领域端口在 `VoiceOSCore`，`Responses*Port` 用严格 JSON Schema 与 `ResponsesEnvelope` 解析；`LocalTextModel.Suite` 统一构造。`AssistantModelPort` 负责现有委托的评估与交付，结果保存为 `ai_text` 来源并做依据核对。
- 任务与提醒：`actions` 需要 claim 与审阅版本，带提醒同步语义；`assistant_executions` 以 `action_id` 为主键关系，承载一次交付。两者都不适合直接承载启动包（路线、结构化字段、确认/复制状态与澄清回合）。

### 可直接复用

- 文字保存与云端授权：`recordUserExpression`、`sourcePolicy`/`setSourceLocalOnly`、转写版本。
- 模型基础设施：`ModelHTTPTransport`、`ResponsesEnvelope`、`ModelConfiguration`、`LocalTextModel.Suite`。
- 界面外壳：`WorkspaceView` 页面与侧栏、`WorkspaceHeading`/`WorkspaceSection`/`WorkspaceRow` 与主题色板、`NSPasteboard` 复制。
- 快照刷新：`WorkspaceSnapshot` 一次同步读取。

### 需要新增

- 任务启动领域类型与纯函数：路线、结构化字段、提示词与教程的确定性拼装、校验。
- 模型端口 `TaskInitiationModelPort` 与 `ResponsesTaskInitiationPort`。
- 迁移 52 的轻量 `task_initiations` 表：草稿/确认与复制时间，不设「完成」。
- 「启动」页面与入口；从材料带入转写文本的入口属于 P0 的 F-01。
- 离线假端口测试，覆盖 T01 到 T13 中与 P0 相关的行为。

### 不采用

- 不扩展 `assistant_executions`：其 `action_id` 非空、输入等价校验与交付形态都围绕「已有待办」，塞入启动包会放宽现有不变量并危及刚修复的助理链路。
- 不把启动包写进 `actions`：那会变成任务并触发提醒语义，违反「不自动建任务」。
- 不把生成结果写成长期认知：P0 只有启动包与来源引用，不产生 claim。

## 决定

并行设计比较了「扩展助理执行管道」与「独立模块」两个方向。采用独立模块：`assistant_executions.action_id` 非空且围绕已有待办，纯问题或吐槽没有可挂的 action，硬接要么伪造 action（等于自动建任务），要么放宽多处输入等价与依据校验，危及现有助理链路。独立模块把失败域隔开，状态只有待澄清/草稿/已确认，复制是时间戳而不是状态。启动包不写成 `ai_text` 来源（恢复校验要求每个 ai_text 来源恰属一次助理交付），只存 `task_initiations`；原口述作为普通个人材料保存，可追溯。迁移 52 建表，P0 不进导出包。

模型只返回语义字段，交接提示词与教程由 `TaskInitiationComposer` 确定性拼装，事实、假设、待确认分栏，`# 请先做的事` 固定要求检查真实环境。用户指定路线时模型必须照做，但原文明确拒绝任务化时仍回到仅记录。

## 验证

- `swift build -j 4` 通过；`swift test -j 4` 82 项 0 失败（原有 72 项，新增 10 项，覆盖 T01 到 T13 的 P0 部分）。新增测试覆盖八段交接包、事实与假设分栏、教程第一步与验证、仅记录不建任务、单问题澄清与跳过、换路线保留一行、复制不改状态、非法提案不落行、密钥提醒与仅本地拒绝、重开后 schema 52 与记录可读。
- 隔离副本 `/tmp/voiceos-initiation-live`（实时库 51 的备份 + APFS 克隆资产），dist 从本分支 release 构建，真实模型走三条路径：
  - 「老师让我做一份PPT，我不会…材料在课程网站的一个压缩包里」→ 先得到「自己动手」教程，含 `# 任务目标`、`# 开始前需要的条件`（假设请先核实 / 待确认分栏）、`# 操作步骤` 6 步；切到「交给 Agent」后得到完整八段交接提示词，`# 请先做的事` 固定要求检查真实环境。
  - 同一交接包复制后，`pbpaste` 内容即交接提示词；数据库 `copied_at` 有值，`state` 仍为 `draft`。
  - 「今天实习任务真烦，我只想吐槽一下，不要安排任务」→ `capture_only`，`state=draft`，无材料，界面显示「已按原意仅记录」；`actions` 459、`claims` 938 前后不变。
  - 退出并重开同一副本：两条启动记录都在，页面默认选中最新一条，schema 52。
- 限制：确认按钮的自动点击未命中（复制与路线切换已命中），确认语义由离线测试覆盖；「从最近材料带入」菜单只核对了渲染，没有选中条目走一遍。实机截图 `/tmp/initiation-13.png`、`/tmp/initiation-16.png`、`/tmp/initiation-20.png`。

## 进展

- 2026-11-10 审计、设计二选一、核心与页面实现、82 项测试通过。分支 `work/task-initiation`，PR 待审。
