# VoiceOS 夜间开发进度

更新时间：2026-10-12 长表达认知提交与入口（Asia/Shanghai）

## 当前权限核对结论

- 稳定签名应用的连接请求最终成功展示清单；取消选择保持原清单授权，界面随后确认“已自动核对VoiceOS验证2026-10-10的关联任务”。此前权限不可用标签属于该次请求完成前的观察，不能代表最终结果。
- 系统设置VoiceOS开关原本on；无需再要求用户开启。未重置TCC或切换清单。已修正请求期间的标签为“正在核对系统提醒事项权限”。当前权限阻塞解除，但真实录音生成行动→外部完成→再次表达仍未验收。
- 最近提交9efa69c为稳定签名实现（后续状态展示切片待提交）。稳定签名与本轮回读成功有直接证据，跨更新/重启的权限连续性尚未证明，详见ADR029。

## 权限与开发身份增量

- 用户明确说明此前已授权。CUA只读确认系统设置VoiceOS提醒事项开关on；旧进程随后曾显示测试清单回读成功。更换签名后重启仍返回权限不可用，不能再把它描述为用户没有打开开关。
- 构建已改用既有唯一Apple Development身份，新DR绑定标识与证书，严格签名校验通过；见[ADR029](../adr/029-stable-development-signing.md)。不导出密钥、不重置TCC或改变系统权限。开发身份稳定性已改善，权限恢复仍待实测。
- 当前应用为稳定签名版本，日常资料库已打开；无录制或云端任务运行。真实提醒事项闭环仍缺权限运行证据，其他工程继续。

## 当前路线与接续状态（schema31）

- 路线已重新映射为 M2→M3 案例A个人录音收口，见[路线当前基线](implementation-roadmap.md)。不扩展现有讨论/英语/通知，尚未宣称任何完整里程碑验收。
- 当前录制路由提交1b6d5a6（前基线ab2abc0）；本轮录制前固定分段计划、长原始逐字稿自动路由、关联阶段落盘、取消间隙/迟到保护与v31冻结迁移见[契约](../engineering/m4-recording-segment-routing.md)。实际提交以git log核验。
- schema31应用编译通过，35项相关检查与2项取消检查通过；末次历史校验后的14项录制相关检查通过。没有后台云端或设备句柄；没有新云端、麦克风或提醒事项写入。
- 原生证据见[阶段UI核对](../research/evidence/recording-route-native-ui-2026-10-12.json)。真实模型/自然语义与提醒事项完整链仍缺；后续先补真实用例，不能据本地夹具宣称案例A通过。
- 真实40分钟已有本人音轨逐字稿的空提案本地夹具完成认知提交，完整性通过；不代表语义质量。日常资料库、原媒体及配置未修改。
- 下一步是阶段原生操作与当前提醒事项权限/连接核对，再验证真实理解及完整反馈链；已读取此前运行应用的原生界面：模型尚未配置、系统提醒事项权限不可用且自动回读暂停。最新源码已签名并通过严格codesign验证；独立库原生CUA确认无配置处理禁用、普通表达本地保存、批次等待/取消终态，模型及关联尝试均0。退出独立库后恢复日常窗口；重新请求既有提醒事项连接确认系统权限不可用，自动回读暂停。全套422项仍为历史证据。父queued和请求enqueued不表示全链完成，超预算关联等仍需明确呈现。

## 前一切片接续状态（历史）

- 基线`f4ac6c0`之后已接入[长表达认知及入口](../engineering/m4-segmented-cognition-entry.md)：schema30、最终提案与行动判断绑定、同事务认知/行动/问题、本地派生身份、v30冻结迁移，Responses兼容文本驱动与控制中心明确入口。实际HEAD以`git log -1`核对。
- 49项相关检查通过；入口编排/配置另6项通过，最新应用编译通过。本轮HTTP使用注入transport，未读取密钥、未调用真实云端、未外写提醒事项；合成长稿不证明自然语义质量。
- 用户要求减弱日常验证：目前未重跑全套、真实SIGKILL、签名或原生界面。阶段末集中核对；旧422项完整回归属于历史。
- 已提交认知有独立身份，不再计为新模型调用、不重生成；旧4000字入口和完整文字回执校验保持。父批次仍待长关联，界面按部分认知完成显示。
- schema30认知切片已提交`290783a`。随后接入长来源历史关联：有效整篇认知前置、固定服务/目的地、复用原8000字关联快照与去重。27项相关检查通过，真实HTTP/UI仍未验收。超过预算保留认知且明确不发送，父状态仍非完整链完成。
- 下一步：录制处理请求的长文字自动分支、超预算关联与整条父状态衔接；原生UI/真实代理兼容与自然闭环验收均未完成。问题超过12000字及断句未解决等工程限制见契约。
- 日常资料库、真实媒体、模型配置未改动；没有后台运行句柄。日志见`runtime/queue-fixes-20261012/segmented-entry-build.log`、`segmented-integration-targeted.log`、`segmented-entry-targeted.log`。

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
