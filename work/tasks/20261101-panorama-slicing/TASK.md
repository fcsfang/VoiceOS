---
status: paused
started: 2026-11-01T01:30+08
updated: 2026-11-01T08:20+08
branch: main
pr: https://github.com/fcsfang/VoiceOS/pull/57, https://github.com/fcsfang/VoiceOS/pull/58, https://github.com/fcsfang/VoiceOS/pull/59, https://github.com/fcsfang/VoiceOS/pull/60, https://github.com/fcsfang/VoiceOS/pull/61, https://github.com/fcsfang/VoiceOS/pull/62, https://github.com/fcsfang/VoiceOS/pull/63, https://github.com/fcsfang/VoiceOS/pull/64, https://github.com/fcsfang/VoiceOS/pull/65
owner: 主会话
---

# 全景分块生成（#55）

## 目标

让超过单请求预算的单元按内容范围分片生成，再确定性合并为同一个单元提案，使最大的两个单元在服务端 600 秒流上限内可靠完成。完成的判据是真实资料库副本上 25/25 单元核验通过，并让关系综合 `global.synthesize` 第一次真实运行。

## 范围

- 单元作用域内按 span 边界做确定性分片规划；只对超过预算的单元生效。
- 模型端口增加带聚焦范围的生成入口，聚焦范围内原话为必需证据，偏移保持全文坐标。
- 分片结果合并为一个单元提案：ID 去重、覆盖清单按整单元重算、回执可审计。
- 分片步骤以确定性身份写入 `panorama_steps`，失败重试复用已完成分片；单元级 `unit.generate` 行保留，跨尝试复用链不变。
- 测试：分片规划、合并覆盖、分片失败隔离与重试复用。

## 非目标

- 不改数据库 schema。
- 不改小单元的请求与既有回执（24 个已完成单元的跨尝试复用必须继续成立）。
- 不并行化分片请求；不改变 `unit.review` 与全局核对的语义。
- 不做 synthesis 分块，除非真实运行证明它撞上同一上限。

## 吞吐检查点

- **阻塞的第一步。** `PanoramaSlicing.swift` 的类型、计划与合并必须先以失败测试落地并通过，才允许接端口与存储；构建与既有测试通过是真实运行前的门。
- **独立工作流。** 类型落地后，端口聚焦请求（`PanoramaModelInput`、`ResponsesPanoramaPort`）与存储编排（分片步骤、组合回执、复用门）可以分开推进，但共享聚焦校验与回执纪律，按单写者串行。
- **共享可变状态。** SQLite 仍由 `VoiceOSStore` 单写；分片行按（attempt、stage、scope、digest）唯一，分片顺序执行，不新增共享。
- **最小安全分解。** 一个实现者拥有全部改动：计划、合并、聚焦校验、回执身份必须逐字一致，拆给多人只会用文字同步编译器不检查的不变量。

## 当前状态

已完成并合入 main 到 77d03b7。

- 分片生成：CE3C1904 四片 5分21秒、4分41秒、8分38秒、2分35秒，单元核验一次通过；ED362352 与 24 个小单元零模型调用复用。
- 全局综合：拆成两轮才可行。第一轮整份输出在 561 秒撞 65,536 token 上限；改为紧凑引用输出后第一次成功，v2 产出 102 个问题、37 条联系、11 个区域，用时 5 分 52 秒。
- 核对链：逐问题、逐联系、逐单元覆盖与一致性核对照常运行，但语义拒绝的尾巴很长。为此合入了覆盖补集本地化、有界修复循环、拒绝确定性重放、按区域取核对上下文、claim 引用、修复摘要最小化。
- 未完成：完成快照尚未产出。最新一轮在 q50 之后继续推进，按用户要求于 08:03 停止，没有正在运行的模型调用。

## 花费与停止

本地今天 00:00 起，副本上共 322 次逐问题核对、15 次综合修复、6 次综合、7 次生成，约 2871 万输入 token、87 万输出 token，另有 13 次失败请求没有回执。大头是核对重复全文。用户看到 API 账单后要求先收尾，运行循环与 40 分钟定时续跑已停止。

## 下一步

- 分批核对：一次核对一组问题，共享全文只读一遍，只修真正被拒的条目；预计把一次完整通过从几十次全文重读降到几次。
- 给真实运行设预算上限（轮数或 token 预算），在单元与综合都缓存的前提下继续核对链。
- 见 issue #66。

## 验证

- `swift build` 通过，`swift test -j 4` 10 项 0 失败。
- 真实副本：25/25 单元核验；global.synthesize 完成并可重放；逐问题核对持续通过到中途，语义拒绝由修复循环逐一处理。
- 花费与阶段耗时记录在 `work/overnight/LOG.md`。

## 链接

- #55 分块生成，含 600 秒服务上限的实测证据。
- #66 综合核对的分批与预算（后续）。
- `docs/adr/043-panorama-sliced-generation.md`、`docs/adr/044-compact-synthesis.md`。
- `work/overnight/LOG.md` 2026-11-01 的测量与花费记录。
