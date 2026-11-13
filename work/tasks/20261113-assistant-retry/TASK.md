---
status: open
started: 2026-11-13
updated: 2026-11-13
branch: work/assistant-retry
pr: pending
owner: coordinator
---

# AI 委托链的结构重试

## 目标

清理面板里残留的「AI 代办未完成」「AI 委托识别未完成」：这些条目多数是模型输出不合规（JSON 缺字段、无法解析）一次失败就终态。目标：像跟进链一样做有界结构重试，并补上这条链完全没有的网络重试。

## 证据（实时库只读盘点）

- 面板显示 6 条委托识别失败：4 条「缺必需字段」、1 条「模型响应无法解析」、1 条 HTTP 403/429，集中在 10 月 20 到 21 日与 11 月 9 日。
- 1 条 AI 代办失败（11 月 10 日）报「数据格式不正确」。全表用当前代码解码一遍，0 条损坏，说明是当天模型响应的问题，不是持久数据坏。
- 根因：`ResponsesAssistantPort.assess` 单次请求后直接 `JSONDecoder().decode`，失败即终态；`execute` 的交付解析与校验同理；`send` 没有任何网络重试。且 `AssistantAssessment` 的自定义解码是宽容的（缺键不抛错），需要一个显式的必填键闸门才能让缺键失败可重试。

## 决定

- 结构重试：识别与交付各最多 3 次；解析或校验失败时把诊断（含 coding path）追加到指令里重问；拒绝与未完成的响应不重试。
- 网络重试：`send` 对 429、502、503、504 与 TLS、超时、连接丢失等传输错误按 5 秒、15 秒退避，最多 3 次；403 等鉴权类错误不重试。
- 必填键闸门：识别结果先检查 intent、supported、kind、reason 四键存在，再交给宽容解码。
- 有界：第三次仍失败则如实记失败。

## 范围

- `Sources/VoiceOSCore/ResponsesAssistantPort.swift`：重试循环、诊断、`retryDelay` 注入口、网络重试。
- `Tests/VoiceOSCoreTests/RetryResilienceChecks.swift`：5 项新测试（缺字段重试、拒绝不重试、无检索交付重试、429 重试、三次仍坏则停）。

## 验证

- `swift build -j 4` 通过；`swift test -j 4` 123 项 0 失败（118 基线 + 5 新增）；先失败测试后实现。
- 未做实时库写操作。部署后由用户在面板重试 6 条识别与 1 条代办验证实际恢复率；403 属鉴权类，重试不会改变结果。

## 进展

- 2026-11-13 实现、测试、复核完成；分支从 main 独立开出。
