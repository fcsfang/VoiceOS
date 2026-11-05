---
status: merged
started: 2026-11-06
updated: 2026-11-06
branch: worktree-agent-a6da969e25b254379
pr: 114
owner: coordinator
---
# 知识核查扫描的空闲成本

## 现象

新构建启动后在空闲状态持续约 140% CPU 数分钟。`sample` 抓到的热路径是 `ControlCenter.resumeKnowledgeReviews()` → `pendingKnowledgeReviews()` → `knowledgeReviews(sourceID:)` → `validateKnowledgeReviewInput` → `prepareKnowledgeReview` → `continuousRecordingContext` → `sources()`，其中大量时间在 SQLite 读取与 JSON 解码完整原文。

同一时刻实时库没有新的模型调用：知识核查共 12 completed、18 failed、10 frozen，最近一条是 11-02。也就是说，应用在周期性重复准备上下文，却没有新工作。

## 根因假设

- `resumeKnowledgeReviews` 在 60 秒定时器、应用激活、唤醒与每次刷新时运行。
- 它对每份合格材料调用 `enqueueKnowledgeReview`；后者先通过 `knowledgeReviews(sourceID:)` 校验每条既有核查，校验会调用 `prepareKnowledgeReview` 重建完整上下文，然后再自己 `prepareKnowledgeReview` 一次。
- `prepareKnowledgeReview` 与 `continuousRecordingContext` 都通过 `sources()` 解码整个资料库的原文；54 份材料下成本很高，且版本未变时结果完全相同。

## 方向

- 在重建上下文前先做廉价的版本签名比较：原话版本、许可版本、观点复核版本、连续表达成员与各自许可、localOnly。
- 签名相同的既有核查直接视为最新，跳过 `prepareKnowledgeReview`；签名变化时仍走完整校验，保持冻结语义不变。
- 用 `sample` 与一个内部准备计数验证前后差异；不得只以“看起来更快”作为证据。
- 先测量再改；改动只进入 `KnowledgeReview.swift` 与测试，不碰界面文件。

## 非目标

- 不改核查提示词、候选与结论语义。
- 不删除既有核查历史。
- 不引入后台常驻进程或新的缓存层。

## 验证

- 同一资料库副本上，修改前后各做一次启动样本，比较热路径占比与空闲 CPU。
- 既有冻结/失效测试全部通过；新增测试覆盖签名相同跳重建、签名变化仍冻结、连续表达变更触发重建。
- `swift build -j 4`、`swift test -j 4`。

## 链接

`/tmp/voiceos-sample.txt`，实时库只读扫描。

## 进展

- PR #112 合入（fe52ff7）：单源且无完整表达的核查在签名一致时跳过重建。夹具 60 份材料 274.7ms→11.5ms、准备 60→0。
- 实时库副本 30 份合格材料：扫描 90 次准备/2.74s（关闭快速路径）→30 次/1.22s（打开），未到零。实时材料 40 份合格中 23 份属于完整表达，10 份既有核查输入与当前不一致，快速路径对它们退回慢路径。
- 剩余：让完整表达与失效输入也走廉价签名；查清首轮扫描与重复扫描的真实成本。实时空闲 CPU 尚未完全消除。
- #114 扩展完整表达与配对材料，实时副本 30 次准备/1.2s→0 次/0.052s；首轮文件校验仍在，工作区刷新成本另行登记。
