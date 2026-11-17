# 波 57：主题正文引文吸附回原文

## 来源

用户实机首跑反馈。批量化主题骨架 5 批与合流全部成功，正文阶段 1 批成功、1 批失败，失败原因 `主题正文的引用无法定位到当前完整原文`（`Sources/VoiceOSCore/TopicOrganization.swift` 的 `validateTopicBody`）。模型有时会把计划引文里的换行、标点改掉或轻微拼接，旧校验只认逐字节子串，导致单个引文漂移让整批主题正文作废。

## 目标

主题阅读卡片里的每条引文都必须是真实录音原文；模型的小幅空白改写被吸附回原文切片，不再整批作废。凭空捏造的引文仍然拒绝。

## 完成判据

1. `validateTopicBody` 返回吸附后的 `TopicBodyResult`。每条 evidence.quote 先找精确子串；找不到时把所有 Unicode 空白与换行的连续段折叠为空后匹配，命中则按归一化索引映射回原文字符区间，取原文切片作为最终引文。归一化后仍找不到则抛「主题正文的引用无法定位到当前完整原文」，并带上来源与引文首 12 个字符。
2. 恢复路径（`reuseCompleted` 分支）与请求路径都用吸附结果执行 `applyTopicBody` 与 `saveStage`；落库引文是原文切片，不是模型原文。
3. 正文提示词在逐字复制要求后补充：换行、空格与标点不得改动；不要用省略号截断；不要把多条引文拼接成一条。输入结构与 schema 不变。
4. 测试覆盖：精确引文通过且回写不变；空白漂移吸附为原文切片；捏造引文仍抛错；整体运行落库吸附后的原文切片。单批失败不影响后续批次已有 `TopicOrganizationSlicingChecks.testSkeletonLandsFirstThenBodiesResumeWithoutRepeatingCompletedBatches` 覆盖，不重复。
5. `swift build -j 2` 与 `swift test -j 2` 真实退出码均为 0，测试 0 失败。

## 文件

- `Sources/VoiceOSCore/TopicOrganization.swift`：`validateTopicBody` 返回类型与吸附算法；恢复、请求两处调用点。
- `Sources/VoiceOSCore/ResponsesTopicOrganizationPort.swift`：正文提示词加固。
- `Tests/VoiceOSCoreTests/TopicOrganizationEvidenceChecks.swift`：4 个用例（纯函数 3 个、隔离临时库 1 个）。

## 吸附算法

精确子串优先。未命中时，把原文与模型引文分别去掉所有 `Character.isWhitespace` 字符（连续空白段折叠为空），在归一化原文中查找归一化引文；记下归一化过程中每个字符对应的原文字符起止位置，命中的归一化区间映射回原文，截取该区间（含区间内部原始空白）作为落库引文。只容许空白差异，字符序列必须一致。

## 结果（2026-11-18）

- `validateTopicBody` 改为返回吸附后的 `TopicBodyResult`：精确子串优先；未命中时所有 Unicode 空白折叠为空后匹配，按归一化索引取原文切片；仍找不到时抛错并带来源与引文首 12 个字符。
- 恢复路径与请求路径都用吸附结果执行 `applyTopicBody` 与 `saveStage`，落库引文为原文切片。
- 正文提示词补充：换行、空格与标点不得改动；不要用省略号截断；不要把多条引文拼接成一条。输入结构与 schema 未变。
- 新增 4 项测试（`TopicOrganizationEvidenceChecks`）：精确引文、空白漂移吸附、捏造拒绝、整次运行落库原文切片；单批失败不中止后续批次由既有 `TopicOrganizationSlicingChecks` 覆盖。
- `swift build -j 2` 真实退出码 0（Build complete，101.07s）；`swift test -j 2` 真实退出码 0，Executed 548 tests, 0 failures。基线 9c0d193（未含消息监测等并行分支）既有 544 项，加本波 4 项。
- 残留风险：归一化匹配取首次出现，同一归一化片段在原文多处出现时可能吸附到靠前位置；未在用户实机资料上复跑正文批次（本轮不联网、不调真实模型）。
