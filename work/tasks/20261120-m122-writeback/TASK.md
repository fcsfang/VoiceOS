# 波 122：外部 agent 写回反馈与完成

基线 `work/m122-writeback`，工作树 `.worktrees/m122-writeback`。目标：本地 agent 执行待办后把结果写回 VoiceOS，写操作必须经 app 进程，不允许直写资料库。121 波的只读 CLI 在本波补上写回。

代码提交 `b5e7b2c feat(writeback): 外部 agent 可写回行动反馈与完成`。

## 数据形状与解析边界

`Sources/VoiceOSCore/ExternalActionCommand.swift` 新增纯解析器：

```swift
public enum ExternalActionCommand {
    case feedback(actionID: String, text: String, kind: ActionFeedbackKind, commandID: String)
    case complete(actionID: String)
}
```

规则：

- `voiceos://action/<uuid>/feedback?text=…&kind=outcome|reflection&command=<uuid>`
- `voiceos://action/<uuid>/complete`
- actionID 必须是 UUID；text 非空且最多 4000 字符；kind 默认 outcome；command 缺省生成 UUID 并校验格式。
- 未知 query 键、重复键、complete 携带 query 一律拒绝；错误为中文 `VoiceOSError`。
- 非 `voiceos` scheme、非 `action` host、单段导航路径（`voiceos://action/<uuid>`）或未知子路由返回 nil，交回既有导航分支。

## 路由映射

`WorkspaceView.routeExternalURL` 在 action host 分支里先调用解析器，命中写回后 return；既有 capture、action/source/topic 导航分支不动。

- feedback：在 `model.actionRecords` 找到行动后调用 `model.saveFeedback(action, kind:text:commandID:)`，与界面反馈表单同一模型方法；成功写 `toastMessage`，失败进 `error` 通道。
- complete：与点击「标记已完成」完全同路。前置同为 task/open/current，然后调用 `applyActionState(action, to: .completed)`，沿用其撤销提示、本地完成提议与错误通道。
- 找不到行动、解析错误都走既有 `error` 状态，不新增通知通道。

## CLI

```
voiceos-cli action feedback <id> --text <text> [--kind outcome|reflection] [--command <uuid>]
voiceos-cli action complete <id>
```

- 先校验参数与 UUID，再探测 `local.voiceos.app` 是否运行（`NSRunningApplication`），未运行 exit 5。
- 用 `URLComponents` 构造写回链接（正文 percent-encode），`NSWorkspace.shared.open` 交给 app。
- 交付后每 0.3 秒新建只读连接轮询，最多 10 秒：feedback 以 `feedbackCount` 增加为观察，complete 以 `state == completed` 为观察；成功 exit 0 并输出含 `observed: true` 的 JSON，超时 exit 4。
- complete 在行动已 completed 时直接返回 observed，不再交付链接。
- 退出码扩展为 0 成功、1 参数或内部错误、2 未找到、3 资料库不可用、4 等待 app 写回超时、5 app 未运行。

## 安全与隐私

- 正文与参数只进入本机 `voiceos://` 链接，绝不写日志；4000 字符上限同时兜住 URL 长度。
- 回写只有 app 进程一条路径，CLI 始终只读打开资料库。
- 本机任意进程都可向 app 发送 `voiceos://`（既有攻击面，本波未扩大），app 仍按 command 收据幂等处理。

## 验证

- `swift build -j 2`：`build_exit=0`。
- `swift test -j 2`：`test_exit=0`，`Executed 696 tests, with 0 failures (0 unexpected) in 46.533 (46.598) seconds`。新增 `ExternalActionCommandChecks` 15 条。
- 中间两次构建失败均为编译错误（`try?` 双重 Optional 压平、`catch` 隐式 `error` 遮蔽视图属性），修复后复跑全绿。

## 端到端（隔离实例）

做法：本工作树 debug 构建的 app 复制到 `/tmp/m122-e2e/VoiceOS.app`，Info.plist 的 bundle id 改为 `local.voiceos.e2e` 并 adhoc 重签，避免与正式实例共用 URL scheme 路由；资料库用 APFS clone（`cp -c`）整库复制，再以 `sqlite3 .backup` 一致快照替换 sqlite；`open -n --env VOICEOS_DATA_DIR=…` 启动，`open -a` 显式把链接交给隔离实例。

结果：

- 隔离实例 lsof 只持有副本的 `store.lock`/`voiceos.sqlite`，对真实库路径的引用为 0。
- feedback：交付后 1 秒内 `feedback_count` 0→1，正文“m122 e2e 验证 反馈”完整往返；整库实例上再验“m122 e2e 完成后的结果”，同样 1 秒落库。
- complete：1 秒内 `state=completed`，`action_revisions` 新增 `version=2,state=completed,actor=user`，actions.version=2。
- 幂等：同一 `--command` 重发 feedback，计数保持 1。
- 正式库前后不变：feedback 总数 23，抽查 B674 仍 open/current/version 1/feedbackCount 0；正式实例 PID 99110 全程存活。

教训：只复制 sqlite 不够。app 启动恢复发现媒体资产缺失，把 1066 条 claim 与全部任务行动冻结为 `frozen`，complete 前置因此拒绝。整库克隆后，启动恢复完成时 B674 仍为 current，complete 前置通过。

## 未做与取舍

- CLI 的“探测 app→交付链接→轮询”链路未对正式 bundle 实跑：本机正式 app 与 URL scheme 共用 `local.voiceos.app`，执行写命令可能落到用户实时库。app 侧写回已用隔离实例验证；CLI 端到端需专用 bundle id 或显式测试开关后再补。
- feedback 以计数增加为观察依据。同一 command 重发时 app 幂等不再新增行，CLI 会按超时 exit 4；需要“重试成功”语义时，只读库目前未暴露 commandID，无法在 CLI 侧直接核对收据。
- complete 对带 externalID 提醒链接的行动在无提醒授权时走本地完成提议，不会直接完成；这与界面路径一致，未为外部写回另开捷径。
- 不改既有 identifier，不动只读命令语义；未 push、未合并、未重启正式应用。