# VoiceOS MCP server

给没有 shell 的 agent 提供 VoiceOS 待办的 MCP 接口。`server.py` 是 voiceos-cli 的薄包装：只做 stdio JSON-RPC 编解码与参数映射，业务逻辑全部留在 CLI。仅用 Python 3 标准库，无第三方依赖。

## 安装

```bash
chmod +x Tools/voiceos-mcp/server.py
swift build --product voiceos-cli
```

CLI 按以下顺序查找，取第一个可执行文件：

1. `$VOICEOS_CLI`
2. `~/.local/bin/voiceos-cli`
3. 仓库 `.build/release/voiceos-cli`
4. `PATH` 中的 `voiceos-cli`

`~/.local/bin` 里的旧二进制会遮住仓库构建。写命令报 `usage` 时，先更新该文件或设置 `VOICEOS_CLI`。

资料库默认 `~/Library/Application Support/VoiceOS`，用 `VOICEOS_ROOT` 指向其他目录。MCP server 从启动它的客户端继承环境变量。

## 注册

仓库根的 `.mcp.json` 已带 `voiceos` 条目。相对路径以 Claude Code 启动目录为基准，所以要在仓库根目录启动，或改用绝对路径：

```bash
claude mcp add voiceos -- python3 /Users/you/VoiceOS/Tools/voiceos-mcp/server.py
```

其他 MCP 客户端等价配置：

```json
{
  "mcpServers": {
    "voiceos": {
      "command": "python3",
      "args": ["/Users/you/VoiceOS/Tools/voiceos-mcp/server.py"]
    }
  }
}
```

## 工具

| 工具 | 参数 | 对应 CLI |
| --- | --- | --- |
| `voiceos_actions_list` | `state`、`validity`、`kind`、`limit`、`offset` | `actions list` |
| `voiceos_actions_show` | `id`（必填）、`include_feedback`、`include_note`、`topics` | `actions show` |
| `voiceos_status` | 无 | `status` |
| `voiceos_action_feedback` | `id`、`text`（必填），`kind`、`command` | `action feedback` |
| `voiceos_action_complete` | `id`（必填） | `action complete` |

成功的工具结果把 CLI stdout 原样放进 `content[0].text`，`isError` 为 `false`。内容是 JSON 字符串，调用方自行解析。非零退出时 `content[0].text` 是 CLI stderr 原文，`isError` 为 `true`。

`voiceos_actions_list` 不提供 `topics`：CLI 的 `actions list` 明确拒绝该参数。需要主题时用 `voiceos_actions_show`。

## 协议

stdio 上的换行分隔 JSON-RPC，支持 `initialize`、`notifications/initialized`、`ping`、`tools/list`、`tools/call`。

- `initialize` 回显请求的 `2025-06-18` 或 `2024-11-05`；其他版本回落到 `2025-06-18`。
- 解析失败 `-32700`，未知方法 `-32601`，参数或工具名不合法 `-32602`，内部异常 `-32603`。
- MCP 层只校验必填、类型与未知字段；取值合法性（例如 `state` 枚举、`kind` 枚举）仍由 CLI 校验，错误经 `isError` 返回。

## 限制

- 写命令要求 VoiceOS app 正在运行。CLI 交付 `voiceos://` 链接后轮询资料库最多 10 秒；server 给子进程 30 秒总预算，超时返回 `isError` 文本。
- 写回幂等靠 `command` UUID；同一次重试复用同一个值。
- 参数与正文不写任何日志；server 正常运行时 stderr 无输出。
- 超时有两层。CLI 交付后轮询最多 10 秒，server 给子进程的总预算是 30 秒。CLI 退出码 4 表示等待 app 写回超时，5 表示 app 未运行。
- 读命令直接只读打开资料库，不需要 app。

## 测试

```bash
python3 Tools/voiceos-mcp/test_server.py
```

测试起真实子进程、走 stdio 协议，并调用真实 voiceos-cli 的只读命令。写命令只验证参数校验路径，不写回资料库。优先用 `.build/debug/voiceos-cli`，其次 release 与 PATH；可用 `VOICEOS_CLI` 覆盖。测试前先构建 CLI。