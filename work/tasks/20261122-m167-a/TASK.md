# 167-A 主题组织测试套件缩减（8 个文件）

## 背景
用户要求缩减 704 项测试规模。允许的缩减只有两种，且必须可审计：
1. **表驱动折叠**：把一个套件里针对同一逻辑的多个 `testXxx` 案例合并为 1 个 `func test…`，每个案例原样作为数据行保留，断言逐条等价（覆盖不减，函数数减少）。
2. **重复删除**：仅当同一不变量已由另一个保留测试（可在同文件或另一套件）断言时删除，并在 TASK 回报中写明对应测试名；无对应者不得删除。

禁止：改动任何生产代码；删除共享 fixture/helper 导致其它测试无法编译；触碰安全类套件。

## 文件清单（只允许动这些）
- Tests/VoiceOSCoreTests/TopicCurationChecks.swift
- Tests/VoiceOSCoreTests/TopicLevelChecks.swift
- Tests/VoiceOSCoreTests/TopicOrganizationBatchChecks.swift
- Tests/VoiceOSCoreTests/TopicOrganizationEvidenceChecks.swift
- Tests/VoiceOSCoreTests/TopicOrganizationHardeningChecks.swift
- Tests/VoiceOSCoreTests/TopicOrganizationSlicingChecks.swift
- Tests/VoiceOSCoreTests/TopicOrganizationStalenessChecks.swift
- Tests/VoiceOSCoreTests/TopicSearchIndexChecks.swift

## 目标
- 这 8 个文件的测试函数总数减少 ≥30%（以 `grep -c "func test"` 计），断言覆盖不降：每个被删除的函数要么其断言进入表驱动行，要么在回报中被指向保留的对应测试。
- 特别注意：主题组织批次/硬化/切片/陈旧性四套件很可能重复驱动同一批组织流程——优先合并这些流程级重复，不要动 TopicLevel 这种纯映射套件的边界值覆盖（可表驱动化）。

## 验证
- 每个改动文件 `xcrun --sdk macosx swiftc -parse` 退出码 0；不跑 swift test（集成轮执行）。
- 回报：改动前后函数计数、每处折叠的表驱动形态、每处删除的对应测试名、parse 退出码、diff --stat。