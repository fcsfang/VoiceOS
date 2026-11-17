# 波 49 任务书（2026-11-17）

## 背景

波 48 已并入 main 前完成构建与全量测试。波 49 处理两项：

1. **全景核对慢性失败**（用户实跑三次，2026-11-13、11-16、11-17 同一单元 B48B173D 反复失败）。证据：
   - `panorama_attempts` 最新一行（24D64FB4，11-17T10:42Z）error 为「1 份材料未能通过核对：FPGA加速开题评议：工作区分与材料规范；已核对 35/36」。
   - 该单元 3 份材料：FPGA（1694 字，0 条观点引用）、固件压缩（5569 字，42 引用）、开题整改（26935 字，157 引用）。
   - 失败文案 `全景引用不能逐字定位或观点归属不符` 出自 `Sources/VoiceOSCore/ThoughtPanorama.swift:368`（`validatePanorama`）。
   - `Sources/VoiceOSCore/ThoughtPanoramaStore.swift:380-381` 的重试分类只把 `PanoramaQuoteLocationFailure`/`PanoramaFocusViolation`/`PanoramaSynthesisReferenceFailure` 视为可重试；`validatePanorama` 抛的普通 `VoiceOSError` 不可重试，生成阶段一次校验失败即单元死亡，无修复通道（unit.repair 只接 review 拒绝）。
   - 模型输入里已带每条观点的 sourceID/transcriptVersionID/start/end（`PanoramaModelInput.Claim.Reference`），因此问题不在信息缺失，而在模型引用错配 + 系统不重试不诊断。

2. **知识核查无已读/接受状态**（backlog，影响 2）：知识页 69 条待核查问题没有「看过/认可/驳回」记录，用户无法收敛。

## 完成判据

1. 全景校验失败有专属错误类型 `PanoramaProposalInvalid`（含分类原因与定位：question/relation id、证据序号、涉及 claim id），`panoramaStep` 对其重试一次（limit 1，与引文定位失败同级）；重试仍失败时，attempt 的 error 文案含具体问题 id 与原因分类，不再是笼统一句话。
2. 单测覆盖：伪端口首次返回归属不符的方案、二次返回正确方案 → 单元通过；伪端口两次都不符 → 抛出可读错误且包含 question id 与「观点归属」字样。测试库用隔离副本模式，不触实时库。
3. 知识核查条目可标记「已读」「认可」「驳回」，状态持久化（新表或 presentations 字段，schema +1），知识页按状态过滤与计数；重启后保留。
4. 单测覆盖状态写入与读取（含 schema 迁移到新版本）。
5. `swift build -j 2` 与 `swift test -j 2` 真实退出码为 0。

## 单元与文件所有权

### Unit PA（全景校验重试与诊断）
- 文件：`Sources/VoiceOSCore/ThoughtPanorama.swift`、`Sources/VoiceOSCore/ThoughtPanoramaStore.swift`、`Tests/VoiceOSCoreTests/PanoramaFlowChecks.swift`（可新增 `PanoramaValidationRetryChecks.swift`）。
- 约束：不改 port 协议签名；retry 走既有 `panoramaStep` 循环；错误文案保持中文用户可读。既有测试中依赖「一次校验失败即抛」的断言需同步更新并说明。

### Unit KB（知识核查状态）
- 文件：`Sources/VoiceOSCore/KnowledgeReview.swift`（或实际核查状态所在文件）、`Sources/VoiceOSCore/CognitiveStore.swift`（schema 迁移）、`Sources/VoiceOSApp/WorkspaceView.swift` 的知识核查区（若在其它视图请自行定位，勿与 PA 冲突）、新增测试文件。
- 约束：schema 版本从 67 迁到 68，迁移幂等；不改动 `followup_digest` 相关逻辑；状态写入走 store 命令而非直接 SQL。

## 集成

- 分支 `work/m49-pa`、`work/m49-kb`，均从 main（波 48 合并后）切出；协调者合并到 `work/mega-49`，单次构建 + 全量测试，记录到本文件「结果」。
- 全程不写实时库；不重启应用（等全部波次与闸门）。

## 结果（2026-11-17）

- PA（d6c778b）：`PanoramaProposalInvalid` 携带问题/联系 id、证据序号与观点 id；`validatePanorama` 全部抛出点换型并拆分顺序诊断；`panoramaStep` 重试分类纳入该类型（limit 1）；attempt 文案带具体定位。新增 PanoramaValidationRetryChecks 三个流程层场景（首次失败二次通过、两次失败、全局综合阶段）。
- KB（247726e）：schema 67→68，`knowledge_review_states(review_id, issue_id, status, updated_at)`；知识核查区计数行、显示全部切换、每条三操作（已读/认可/驳回），资料页问题区同样带操作；启动校验拦截孤儿状态。KnowledgeReviewStateChecks 六项覆盖写入/读取/覆盖/计数/过滤/重启与迁移幂等。
- 集成：mega-49 合并无冲突。构建 build_exit=0（71s）；测试 test_exit=0，514 项 0 失败（28s）。
- 部署：与波 48 同机安装需下一次闸门重启（schema 68 随包迁移）。
