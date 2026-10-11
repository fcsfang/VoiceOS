# VoiceOS 夜间开发进度

更新时间：2026-10-12（Asia/Shanghai）

## 当前目标

完成明确个人文字的持久处理意图、可恢复执行器、迁移兼容和“保存并处理本次文字”入口，保持认知—行动—反馈边界与既有授权契约。

## 接手核验

- 工作区：`main`，相对 `origin/main` ahead 69；接手时工作区干净。
- 最近基线提交：`99a01e6`；本轮持久队列切片已提交（当前 HEAD）。
- 接手时没有 VoiceOS、Swift 测试或构建进程运行。
- schema 当前为 24，PortablePackage 当前为 v23；持久 `processing_intents` 尚未存在。

## 当前切片

schema 25 与 `processing_intents` 持久身份/状态、串行执行器、迁移包和原生入口均已接入。所有外部调用继续使用既有端口、授权和 attempt 回执；unknown 不自动重发。

## 运行与证据

当前没有后台运行句柄。

- `swift test`：345 项通过。
- `git diff --check`：通过。
- `python3 scripts/app/build.py --semantic-model runtime/bge-coreml-2026-10-11`：签名构建通过。
- 新增队列夹具：一次认知/一次关联、终态不重发、取消不派发、PortablePackage v24 往返并冻结：通过。
- 旧包/旧 schema 迁移回归及现有全套恢复测试：通过。
- 原生 UI：已启动签名应用，但 CUA 报告 macOS 当前锁定，未能读取窗口；需要解锁后再做用户可见按钮和状态的实际核对。

## 未完成与下一步

- [x] schema 25 migration 和存储 API
- [x] 可恢复串行执行器及阶段状态
- [x] PortablePackage v24 / schema 25 往返与旧包兼容
- [x] App 明确“保存并处理本次文字”入口和状态投影
- [ ] 中断、重复恢复、取消、篡改包和原生 UI 验证

## 下一安全切片

补充真实 SIGKILL 阶段边界和处理意图篡改包负例；解锁后核对原生控制中心。不得把当前合成夹具和构建结果扩大解释为自然语音质量或完整 MVP 验收。
