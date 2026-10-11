# VoiceOS 夜间开发进度

更新时间：2026-10-12 03:56（Asia/Shanghai）

## 当前目标

完成明确个人文字的持久处理意图、可恢复执行器、迁移兼容和“保存并处理本次文字”入口，保持认知—行动—反馈边界与既有授权契约。

最新提交：`514ad09 docs: add third-party overnight target prompt`；当前工作区已清理。若服务切换或上下文压缩，先核对该提交、`git status` 和本文件，再继续。

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

- `swift test`：350 项通过，0 failures（含取消竞态、快照/授权漂移和篡改迁移包负例）。
- `git diff --check`：通过。
- `python3 scripts/app/build.py --semantic-model runtime/bge-coreml-2026-10-11`：最新签名构建通过。
- `codesign --verify --deep --strict --verbose=2 dist/VoiceOS.app`：签名有效；`voiceos-check expression-queue-fixture` 在新隔离库完成认知/关联并保持完整性，读回显示两阶段 attempt 身份。
- 最终恢复探针输出：`processingIntentUncommitted` 无残留、`processingIntentCommitted` 为 `queued`，其余三个阶段均为 `unknown`；无云端调用或提醒事项写入。
- 新增队列夹具：一次认知/一次关联、终态不重发、取消不派发、PortablePackage v24 往返并冻结：通过。
- `scripts/probes/expression-processing-recovery.py`：五个实际 SIGKILL 检查点覆盖入队未提交（无意图）、入队已提交（queued）、意图 running、认知 reserved、关联 reserved；恢复状态符合预期，第二次恢复稳定；证据见 `docs/research/evidence/expression-processing-recovery-2026-10-12.json`。
- 本轮 03:54 重新运行 `swift test`：350 项通过，0 failures；随后重新运行恢复探针，五个 SIGKILL 边界仍分别为 absent、queued、unknown、unknown、unknown，未产生云端调用或提醒事项写入。
- 取消竞态回归：认知或关联在途时取消，迟到的已接收结果保留用量和历史，但认知上下文/候选及关联回执冻结，不进入下一阶段；关联和模型调用各执行一次。
- 快照漂移回归：入队后更正文字或撤回云端授权均在模型调用前进入 blocked，认知与关联端口调用次数为 0。
- 控制中心新增“处理记录”菜单：显示 queued/running/completed/unknown/blocked/cancelled/frozen/rejected 与阶段/错误，queued/running 可明确取消；`swift build` 编译通过，原生运行时仍待解锁核对。
- 旧包/旧 schema 迁移回归及现有全套恢复测试：通过。
- 原生 UI：已启动签名应用，但 CUA 报告 macOS 当前锁定，未能读取窗口；需要解锁后再做用户可见按钮和状态的实际核对。
- 本轮 CUA 再次确认同一锁定状态；没有伪造 UI 证据，也没有重复启动应用。

## 未完成与下一步

- [x] schema 25 migration 和存储 API
- [x] 可恢复串行执行器及阶段状态
- [x] PortablePackage v24 / schema 25 往返与旧包兼容
- [x] App 明确“保存并处理本次文字”入口和状态投影
- [x] 处理意图篡改包负例（同步更新 manifest 校验和仍拒绝）
- [ ] 原生 UI 运行时验证（按钮、状态、取消和重启后的 unknown）

## 下一安全切片

解锁后核对原生控制中心；随后再做适用的签名构建和最终切片审查。不得把当前合成夹具和构建结果扩大解释为自然语音质量或完整 MVP 验收。
