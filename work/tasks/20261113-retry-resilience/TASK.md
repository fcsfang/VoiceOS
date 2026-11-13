---
status: open
started: 2026-11-13
updated: 2026-11-13
branch: work/retry-resilience
pr: 138
owner: coordinator
---

# 重试韧性：网络错误与随机合规失败的自愈

## 目标

用户在实时库手动发起批量重试后，仍有 6 条失败（2 条跟进、4 条知识核查）。目标：让这些可自愈的失败类别能在系统内自愈，而不是永远等人工逐条重试。

## 证据（副本实测与原始回执）

- 两条跟进失败（97E6E9D5「跟进结果引用不是连续原话」、661A8A3C「旧观点引用不符」）在副本上用同一条目重新生成一次即全部通过（2/2）。97E6E9D5 的机理：模型把原文中一串「嗯。嗯。嗯。呃」的口吃段删改压缩，首尾逐字、中间改写，稳定触发逐字校验。
- 四条知识核查失败全部是传输层：TLS 握手失败 ×3、请求超时 ×1。知识核查链没有任何网络重试；跟进链的瞬时错误分类漏了 `.secureConnectionFailed`。
- 一条「调研未取得真实检索引用」在重跑时先被 TLS 挡住，未取得干净样本，不凭猜修改。

## 决定

- 知识核查端口：在既有 3 次尝试循环里，把 `.timedOut`、`.cannotFindHost`、`.cannotConnectToHost`、`.networkConnectionLost`、`.notConnectedToInternet`、`.dnsLookupFailed`、`.secureConnectionFailed` 与 429/5xx 同等对待，沿用 5 秒/15 秒退避；其他错误原样抛出。
- 跟进瞬时分类补 `.secureConnectionFailed`。
- 跟进合规失败：有界自动重试一次（60 秒延迟，retryCount 记 1）；第二次仍失败则保持 failed。端口层的校验错误用内部标记包住，生成失败解包后能识别；来源/授权变化与取消不进入此分支。
- 提示词：明确引文必须原样连续复制，保留重复口头语与语气词，不得删改、压缩、拼接；无法连续复现时改引更短片段。

## 范围

- `Sources/VoiceOSCore/ResponsesKnowledgeReviewPort.swift`（网络重试与可注入退避）。
- `Sources/VoiceOSCore/RecordingFollowup.swift`（分类补码、合规标记与有界调度）。
- `Sources/VoiceOSCore/ResponsesRecordingFollowupPort.swift`（端口校验打标、提示词引文规则）。
- `Tests/VoiceOSCoreTests/RetryResilienceChecks.swift`（新增 7 项）；`CoreFlowTests` 中「语义拒绝必须终态」的旧断言随新行为更新为「有界再试一次」。

## 验证

- 先失败测试后实现；`swift build -j 4` 通过，`swift test -j 4` 117 项 0 失败（110 基线 + 7 新增）。
- 副本验证（实时库快照，修复后构建）：知识核查 5335D61B 在网络抖动中完成；71C07C85 运行中；两条仍遭 TLS/超时风暴失败。网络许可时可自愈，风暴中仍会如实失败。
- 合规自动重试由按生产包装形状的单元测试覆盖（端口把校验失败包成生成失败，存储层解包后调度一次）。

## 备注

- 跟进瞬时重试与合规重试共用 retryCount 预算；改写作息时间统一为默认 ISO8601 输出，测试可解析。
- 「调研无真实检索」类暂不加重试，等待干净样本后再定。

## 进展

- 2026-11-13 三项修复与 7 项测试完成；分支从 main 独立开出。
