# 波 123：VoiceOS 待办 MCP 接口

基线 `work/m123-mcp`，工作树 `.worktrees/m123-mcp`。目标：没有 shell 的 agent 通过 MCP 读写 VoiceOS 待办。实现是 voiceos-cli 的薄包装，不复制业务逻辑，不直写资料库。

## 协议面

`Tools/voiceos-mcp/server.py` 只依赖 Python 3 标准库，在 stdio 上跑换行分隔 JSON-RPC：

- `initialize` 回显 `2025-06-18` 或 `2024-11-05`，其他版本回落到 `2025-06-18`；返回 `capabilities.tools` 与 `serverInfo {name: voiceos, version: 0.1.0}`。
- `notifications/initialized` 与所有无 `id` 消息不产生响应。
- `ping` 返回空对象；`tools/list` 返回 5 个工具及 JSON Schema；`tools/call` 执行工具。
- 错误码：`-32700` 解析失败，`-32600` 非对象或缺 method，`-32601` 未知方法，`-32602` 参数或工具名不合法，`-32603` 内部异常。

工具成功时把 CLI stdout 原样放进 `content[0].text`，`isError:false`；非零退出把 stderr 原文放进同一位置，`isError:true`。参数与正文不写日志。

## 工具 schema

| 工具 | required | properties | CLI |
| --- | --- | --- | --- |
| `voiceos_actions_list` | 无 | state、validity、kind、limit、offset | `actions list` |
| `voiceos_actions_show` | id | id、include_feedback、include_note、topics | `actions show` |
| `voiceos_status` | 无 | 无 | `status` |
| `voiceos_action_feedback` | id、text | id、text、kind、command | `action feedback` |
| `voiceos_action_complete` | id | id | `action complete` |

每个 schema 都是 `type:object` 且 `additionalProperties:false`。MCP 边界只校验必填、类型与未知字段；枚举取值（state、validity、kind）交给 CLI，保持单一事实来源。参数以列表传给 `subprocess.run`，不拼 shell；子进程超时 30 秒，覆盖写命令内建的 10 秒轮询。

CLI 路径解析顺序为 `$VOICEOS_CLI`、`~/.local/bin/voiceos-cli`、仓库 `.build/release/voiceos-cli`、`PATH`，取第一个可执行文件。

## 变化文件

- `Tools/voiceos-mcp/server.py`：协议循环与工具注册表；`build_args` 是纯函数，只把参数字典变成 CLI 参数列表。
- `Tools/voiceos-mcp/test_server.py`：13 项 stdio 端到端检查。
- `Tools/voiceos-mcp/README.md`：安装、注册、工具、限制。
- `.mcp.json`：仓库根 `voiceos` server 条目，相对路径以启动目录为基准。

## 验证

`swift build --product voiceos-cli`：构建退出码 0，17.05 秒，产物 `.build/debug/voiceos-cli`。

`python3 Tools/voiceos-mcp/test_server.py`：`Ran 13 tests in 0.121s`，`OK`，退出码 0。覆盖：

- initialize 与两种协议版本、未知版本回落；
- tools/list 的 5 个工具、必填集、schema 形状与列表字段集；
- status 与 actions list limit=1 的真实 JSON；
- 缺失 id 的 show 返回 `not_found` 与 `isError:true`；
- feedback 缺 text 在 MCP 边界返回 `-32602`；
- feedback 非法 kind 到达 CLI 后返回 `isError:true`，证明 stderr 透传；
- 未知参数、未知工具、未知方法、解析错误与 ping。

测试读取真实资料库的只读命令，不写回。写命令只走参数校验路径。

## 未做与取舍

- `voiceos_actions_list` 不暴露 `topics`。任务描述列了该参数，但本分支 CLI 的列表分支明确拒绝 `--topics`（只允许 `actions show`），保留一个必然报错的字段没有价值。需要主题时用 `voiceos_actions_show`。
- 写命令没有端到端回写。server 测试只验参数校验路径；真实回写会落到用户实时库，122 波已用隔离 app 实例验证 app 侧写回。
- 30 秒子进程超时分支未实跑，需要挂起 CLI 30 秒；实现用 `TimeoutExpired` 折成 `isError`。
- `~/.local/bin/voiceos-cli` 当前构建早于写命令，缺 `action feedback`。路径顺序按任务要求保留全局二进制优先；测试用 `VOICEOS_CLI` 指向分支构建，README 记录了遮蔽风险。
- `.mcp.json` 用相对路径，依赖从仓库根启动；README 另给绝对路径的 `claude mcp add` 示例。
- 未 push、未合并、未开 PR。