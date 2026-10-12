# VoiceOS 夜间开发进度

更新时间：2026-10-12 日间个人录音持久链切片（Asia/Shanghai）

## 当前接续状态

- 审核基线 `6c60080`；四项 P2 已修复：语义命令指纹、真实调用身份、迁移来源/权限绑定、按实际回执安全恢复。
- 上一审核修复切片 362 项回归通过，七个实际强退窗口含结果提交后续接与终态重放通过；schema25 / 包 v24 保持兼容，不增加模型重试或迁移自动派发。
- 原生界面已解锁；最新签名构建的 queued→cancelled、unknown 呈现、未配置模型按钮禁用和普通本地保存经 CUA/落盘核对。真实云端 running 的 UI 取消仍未验收，已有阻塞端口核心回归覆盖在途取消。
- 用户授权同一期播客的两段视频用于测试。两段各 45 秒样本已完成本地导入/转写，首段另查一条重复文字音轨；未上传媒体、未调用文本模型、未外写提醒事项。
- 最新说明及证据先读[修复记录](../engineering/m4-expression-processing-reliability.md)；下文保留夜间历史，不作为当前“只剩 UI”的结论。实际 HEAD 用 `git log -1` 核对，避免为文档自引用反复提交。
- 当前回归365项通过，签名构建/校验和个人录音原生导入转写通过。包含新个人录音来源时为v25，旧范围仍输出v24；schema25。
- 已接入个人录音逐字稿持久链与明确归属导入；用户确认轨1混合、轨2本人、轨3电脑声音。第二段本人轨45秒完成真实本地转写及确定性队列、重放与v25包恢复验证。详见[个人录音切片](../engineering/m4-personal-audio-processing.md)。
- 下一安全切片：选取有声音的外部轨、人工核对逐字稿/引用，再补转写前显式持久请求和完整自然闭环验收。

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
