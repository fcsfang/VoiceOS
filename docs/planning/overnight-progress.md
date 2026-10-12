# VoiceOS 夜间开发进度

更新时间：2026-10-12 整篇聚合持久调用（Asia/Shanghai）

## 当前接续状态

- 基线`d1e1f4d`之后已实现[聚合持久调用](../engineering/m4-segment-aggregation-attempt.md)：schema29，单父唯一预留/整篇判断暂存，未知不重发、取消/漂移迟到结果冻结、恢复与v29迁移。实际HEAD用`git log -1`核对。
- 本轮按用户的新要求降低验证频率：编译及31项直接相关检查通过；没有完整回归、签名/UI、真实SIGKILL或真实云端验证。上一版本422项全量通过保持历史证据，不能作为当前版本全量结论。专项未测范围见聚合契约。
- 聚合结果暂存后父批次仍queued，不创建claims/questions/actions/outbox；最终认知提交、长来源关联、真实云端与原生执行入口仍未实现。
- 下一步：整篇响应的最终认知/行动提案与证据绑定、原子提交到现有实体；保留旧完整文字上下文/4000字回执校验。阶段末集中做完整验证。
- 本轮没有新费用、媒体上传、麦克风或提醒事项写入，没有改变日常资料库配置。提醒事项权限此前不可用，本轮未刷新；自然闭环与完整MVP未验收。
- 日志：`runtime/queue-fixes-20261012/aggregation-build.log`、`aggregation-targeted.log`；没有后台运行句柄。

## 前一切片检查点（保留历史证据）

- 最新实施见[片段提取契约](../engineering/m4-segment-extraction.md)及[ADR027](../adr/027-durable-segment-extraction.md)。实际HEAD用`git log -1`核对，避免为文档自引用反复提交；基于`525292a`完成本轮切片。
- schema28，独立片段预留/结果暂存、单资料库串行片段执行、全局producer顺序及持久证据消费门槛已实现。含尝试数据导出v28，只有父批次仍v27，其他范围保持v24/v25/v26。
- 415项回归通过；三个实际SIGKILL窗口分别覆盖片段预留、结果事务未提交及已提交。前两者unknown不重发，已提交结果仅续未预留段。之前父入队/取消的四窗口证据继续保留。
- 取消、更正/撤权/隔离立即冻结子尝试；迟到响应保留历史与已知用量，不激活产品实体、不覆盖父终态。结果提交后的检查点异常不重写成功回执。
- 全部片段完成后父批次仍queued，等待尚未实现的整篇聚合。片段提案不能创建claims/questions/actions/outbox；旧整份逐字稿回执校验和4000字入口未放宽。
- 真实40分钟本人音轨（第二段视频，轨2，偏移120秒，时长2400秒）的5280字符分为2段。本轮本地夹具固定返回空提案，两段完成、v28引用导出及恢复冻结通过；这是执行机制证据，不是自然理解质量验收。媒体、逐字稿和包留在忽略的runtime。
- 新增篡改负例在重算内层及manifest摘要后仍拒绝：伪造政策、完成quote、与旧model_attempts冲突的producer顺序。来源更正后的合法旧历史仍可读取。
- 签名构建与`codesign --verify --deep --strict`通过；本切片没有原生UI改动或云端、麦克风、提醒事项写入。没有后台运行句柄。日志位于`runtime/queue-fixes-20261012/segment-extraction-*.log`，脱敏[验证证据](../research/evidence/segment-extraction-validation-2026-10-12.json)与[强退证据](../research/evidence/segment-extraction-recovery-2026-10-12.json)已保存。
- 片段切片已提交为`352524e`。随后[整篇判断结构门槛](../engineering/m4-segment-aggregation-validation.md)接入，最新422项回归通过：全部证据和潜在行动恰好覆盖、原话依据、重复链无环且指向保留项、未完句阻塞。持久消费入口校验及取消后拒绝通过，不创建认知/行动实体；这是本地校验，不是聚合成功回执。最新签名构建与严格codesign校验通过，无后台句柄；新证据见整篇判断契约。
- 下一步：持久聚合预留、全部潜在行动accept/reject/ambiguous/duplicate覆盖、未完句门槛和最终原子认知提交；再接长来源关联、真实云端及原生入口。完整自然闭环和MVP仍未验收。
- 原个人文字队列、录制请求、轨2归属、无损分段原生预览及历史审核修复已实现，勿重复实施。详见[修复记录](../engineering/m4-expression-processing-reliability.md)、[录制请求](../engineering/m4-recording-processing-request.md)、[无损计划](../engineering/m4-transcript-segmentation.md)。
- 日常资料库和用户11.4秒录音此前已恢复，本切片未切换或修改。提醒事项连接此前显示权限不可用/自动回读暂停，本轮未刷新其状态；不能据旧授权宣称当前回读可用。真实云端running的UI取消仍待验收。

## 夜间历史记录（截至 04:32）

## 当前目标

完成明确个人文字的持久处理意图、可恢复执行器、迁移兼容和“保存并处理本次文字”入口，保持认知—行动—反馈边界与既有授权契约。

历史检查点：`e52e9db docs: correct latest regression counts`。服务切换或上下文压缩后先读顶部当前接续状态，再核对 `git status` 和 `git log`。

## 接手核验

- 工作区：`main`；当前工作区干净。交接时相对 `origin/main` ahead 69，之后新增提交已留在本地分支。
- 交接历史基线为 `99a01e6`；当前队列、恢复、取消、迁移和 UI 状态切片已提交，最新提交见本文件顶部。
- 接手时没有 VoiceOS、Swift 测试或构建进程运行。
- 交接时历史 schema 为 24、PortablePackage v23，尚无持久 `processing_intents`；当前已升至 schema25 / PortablePackage v24。
- 本轮接手时发现签名 VoiceOS 进程仍在运行；未重复启动。CUA 读取失败，原因是 macOS 当前锁定。

## 当前切片

schema 25 与 `processing_intents` 持久身份/状态、串行执行器、迁移包和原生入口均已接入。所有外部调用继续使用既有端口、授权和 attempt 回执；unknown 不自动重发。

## 运行与证据

当前没有后台运行句柄。

- `swift test`：353 项通过，0 failures（含取消竞态、快照/授权漂移、配置漂移、冻结认知、queued 迁移冻结和篡改迁移包负例）。
- `git diff --check`：通过。
- `python3 scripts/app/build.py --semantic-model runtime/bge-coreml-2026-10-11`：最新签名构建通过。
- `codesign --verify --deep --strict --verbose=2 dist/VoiceOS.app`：签名有效；`voiceos-check expression-queue-fixture` 在新隔离库完成认知/关联并保持完整性，读回显示两阶段 attempt 身份。
- 最终恢复探针输出：`processingIntentUncommitted` 无残留、`processingIntentCommitted` 为 `queued`，其余三个阶段均为 `unknown`；无云端调用或提醒事项写入。
- 新增队列夹具：一次认知/一次关联、终态不重发、取消不派发、PortablePackage v24 往返并冻结：通过。
- `scripts/probes/expression-processing-recovery.py`：五个实际 SIGKILL 检查点覆盖入队未提交（无意图）、入队已提交（queued）、意图 running、认知 reserved、关联 reserved；恢复状态符合预期，第二次恢复稳定；证据见 `docs/research/evidence/expression-processing-recovery-2026-10-12.json`。
- 本轮 04:24 重新运行 `swift test`：353 项通过，0 failures；配置漂移和 queued 迁移冻结回归均确认模型和关联调用为 0。
- 取消竞态回归：认知或关联在途时取消，迟到的已接收结果保留用量和历史，但认知上下文/候选及关联回执冻结，不进入下一阶段；关联和模型调用各执行一次。
- 快照漂移回归：入队后更正文字或撤回云端授权均在模型调用前进入 blocked，认知与关联端口调用次数为 0。
- 控制中心新增“处理记录”菜单：显示 queued/running/completed/unknown/blocked/cancelled/frozen/rejected 与阶段/错误，queued/running 可明确取消；`swift build` 编译通过，原生运行时仍待解锁核对。
- 旧包/旧 schema 迁移回归及现有全套恢复测试：通过。
- 原生 UI：已启动签名应用，但 CUA 报告 macOS 当前锁定，未能读取窗口；需要解锁后再做用户可见按钮和状态的实际核对。
- 本轮 CUA 再次确认同一锁定状态；没有伪造 UI 证据，也没有重复启动应用。
- 04:12 等待后再次核对，macOS 仍锁定；UI 证据保持未验证，未重复启动或终止现有应用进程。
- 静态审查发现无文本模型时 queued 意图会触发空转重排队；已在 `0aa8b9a` 修复：无模型时保持 queued 且不循环，成功选择模型后由配置入口唤醒一次；编译、350 项测试、恢复探针和签名验证均通过。
- 新隔离库 `runtime/queue-fixture-20261012-0401` 实跑 `voiceos-check expression-queue-fixture` 与 `expression-queue-read`：integrity=true，认知和关联各一次，读回保留两阶段 attempt 身份。
- 静态审查又发现冻结的既有认知被执行器当成成功并继续关联；`5d759b8` 已改为在 cognition 阶段落盘 `frozen` 终态并跳过关联，新增回归证明认知/关联调用均为 0。完整回归现为 351 项通过；恢复探针、签名构建和 codesign 验证继续通过。
- `.build/debug/voiceos-check config-check 'docs/模型api 配置.md'` 脱敏检查通过：配置可加载，模型为 `gpt-6.1-sol`，识别六个端口；未发送请求且未输出密钥。
- 已刷新原始夜间交接提示词，明确当前队列已完成、353 项回归通过以及 UI 锁定阻塞，避免后续服务切换重复实现队列。
- 新增 queued 意图迁移回归：恢复后状态为 frozen，尝试执行不调用认知或关联端口；本轮完整回归为 353 项通过。
- 04:29 CUA 再次确认 macOS 仍锁定；原生 UI 证据保持未验证，未重复启动或终止 VoiceOS 进程。
- 04:32 等待后 CUA 仍报告 macOS 锁定；未重复启动或终止 VoiceOS 进程。

## 未完成与下一步

- [x] schema 25 migration 和存储 API
- [x] 可恢复串行执行器及阶段状态
- [x] PortablePackage v24 / schema 25 往返与旧包兼容
- [x] App 明确“保存并处理本次文字”入口和状态投影
- [x] 处理意图篡改包负例（同步更新 manifest 校验和仍拒绝）
- [ ] 原生 UI 运行时验证（按钮、状态、取消和重启后的 unknown）

## 下一安全切片

解锁后核对原生控制中心；随后再做适用的签名构建和最终切片审查。不得把当前合成夹具和构建结果扩大解释为自然语音质量或完整 MVP 验收。
