---
status: in_progress
started: 2026-11-15
updated: 2026-11-15
branch: work/mega-18
owner: coordinator
---

# 测试套件提速与去冗余

## 目标

用户问测试是否过多、能否删冗余加快开发。实测：352 项 55 秒，其中 `testIdeaFindsHistoryWithoutCreatingTask` 一条 35.19 秒（全量 64%），其余 351 条共 20 秒。目标是在不丢行为覆盖的前提下把全量压到 20 秒以内，并消除真正的冗余。基线 `main` 为 `3b3d9d4`。

## 实测数据

- 全套件 55 秒；CoreFlowTests 48 秒；其余 43 个文件 7 秒。
- 巨型测试内部：`assertPanoramaProgressiveRecovery` 11.58 秒、`assertPanoramaSlicedGeneration` 6.43 秒、`assertPanoramaQuoteRetry` 1.08 秒、`assertPanoramaDatabaseReopens` 0.05 秒、`assertPanoramaSchemaRepair` 0.01 秒、`assertPanoramaTitleChangeContinues` 0.15 秒；其余约 16 秒在想法→历史→讨论流程本身。
- 存储创建（含 62 个迁移）0.035 秒，不是瓶颈。
- 9 处 schema 版本断言硬编码 62，每次迁移要改 9 处。

## 单元

### T1 巨型测试拆分与剖面
文件：`Tests/VoiceOSCoreTests/CoreFlowTests.swift`、`PanoramaFlowChecks.swift`。
- 把 6 个全景断言从想法测试中拆出去，每个场景成为独立测试方法（同名场景前缀 `testPanorama...`）。
- 用同样方法剖面想法→历史→讨论流程剩下的约 16 秒，找出热点的具体调用（写入、检索、checkpoint 备份、FTS 触发等），给出证据后优化热点，不靠删断言。
- 若切片/恢复场景的耗时来自夹具规模（单元数、切片数、重试次数），把规模降到覆盖语义所需的最小值，并在测试里注明规模是语义所需。

### T2 去冗余
文件：`Tests/VoiceOSCoreTests/`。
- 找出真正重复的覆盖（同一行为在多个套件断言），逐条给证据后合并或删除；不做「跑得慢就删」。
- 9 处 schema 版本断言收敛到一个 helper 常量，迁移时只改一处。

## 验证

- 全量 `swift test -j 2` 通过，测试数可减但每处删除要有「同一行为已被 X 覆盖」的证据。
- 记录优化前后每套件耗时对比。

## 已知边界

- 不动产品代码，除非剖面证明是核心性能缺陷（如 checkpoint 全库备份）且修复行为等价。
- 不引入测试并行或 xdist 类机制，先做单进程提速。

## 结果

（待填）

## 链接

- `Tests/VoiceOSCoreTests/CoreFlowTests.swift`
