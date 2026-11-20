#!/usr/bin/env python3

import json
import os
import shutil
import subprocess
import sys

PROTOCOL_VERSIONS = ("2025-06-18", "2024-11-05")
DEFAULT_PROTOCOL_VERSION = "2025-06-18"
SERVER_INFO = {"name": "voiceos", "version": "0.1.0"}
CLI_TIMEOUT_SECONDS = 30


def _list_args(params):
    args = ["actions", "list"]
    for flag, key in (("--state", "state"), ("--validity", "validity"), ("--kind", "kind")):
        if params.get(key) is not None:
            args.extend([flag, str(params[key])])
    if params.get("limit") is not None:
        args.extend(["--limit", str(params["limit"])])
    if params.get("offset") is not None:
        args.extend(["--offset", str(params["offset"])])
    return args


def _show_args(params):
    args = ["actions", "show", params["id"]]
    if params.get("include_feedback"):
        args.append("--include-feedback")
    if params.get("include_note"):
        args.append("--include-note")
    if params.get("topics"):
        args.append("--topics")
    return args


def _status_args(params):
    return ["status"]


def _feedback_args(params):
    args = ["action", "feedback", params["id"], "--text", params["text"]]
    if params.get("kind") is not None:
        args.extend(["--kind", str(params["kind"])])
    if params.get("command") is not None:
        args.extend(["--command", str(params["command"])])
    return args


def _complete_args(params):
    return ["action", "complete", params["id"]]


TOOLS = {
    "voiceos_actions_list": {
        "description": "列出 VoiceOS 待办。可按状态、有效性、种类筛选并分页；返回 voiceos-cli 的 JSON 原文。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "state": {"type": "string", "enum": ["open", "completed", "dismissed", "someday"],
                          "description": "行动状态"},
                "validity": {"type": "string", "enum": ["current", "frozen"],
                             "description": "有效性；current 为当前有效，frozen 为已冻结"},
                "kind": {"type": "string", "enum": ["task", "opportunity", "ai_suggestion"],
                         "description": "行动种类"},
                "limit": {"type": "integer", "minimum": 1, "maximum": 1000,
                          "description": "返回条数，默认 100"},
                "offset": {"type": "integer", "minimum": 0, "description": "分页偏移"},
            },
            "required": [],
            "additionalProperties": False,
        },
        "build_args": _list_args,
    },
    "voiceos_actions_show": {
        "description": "查看单条待办的详情，可附带反馈元数据、备注与所属主题。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "id": {"type": "string", "description": "行动 UUID"},
                "include_feedback": {"type": "boolean", "description": "附带反馈元数据"},
                "include_note": {"type": "boolean", "description": "附带备注"},
                "topics": {"type": "boolean", "description": "附带所属主题"},
            },
            "required": ["id"],
            "additionalProperties": False,
        },
        "build_args": _show_args,
    },
    "voiceos_status": {
        "description": "资料库概况：schema 版本、各状态行动数、材料与主题数。",
        "inputSchema": {"type": "object", "properties": {}, "required": [],
                        "additionalProperties": False},
        "build_args": _status_args,
    },
    "voiceos_action_feedback": {
        "description": "把执行结果写回 VoiceOS 行动。需要 VoiceOS app 正在运行；正文不会写入任何日志。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "id": {"type": "string", "description": "行动 UUID"},
                "text": {"type": "string", "description": "反馈正文，最多 4000 字符"},
                "kind": {"type": "string", "enum": ["outcome", "reflection"],
                         "description": "反馈种类，默认 outcome"},
                "command": {"type": "string",
                            "description": "幂等命令 UUID；重试同一次写回时复用"},
            },
            "required": ["id", "text"],
            "additionalProperties": False,
        },
        "build_args": _feedback_args,
    },
    "voiceos_action_complete": {
        "description": "把行动标记完成，与界面「标记已完成」同一路径。需要 VoiceOS app 正在运行。",
        "inputSchema": {
            "type": "object",
            "properties": {"id": {"type": "string", "description": "行动 UUID"}},
            "required": ["id"],
            "additionalProperties": False,
        },
        "build_args": _complete_args,
    },
}


class RpcError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def _validate(schema, arguments):
    if not isinstance(arguments, dict):
        return "arguments 必须是对象"
    properties = schema.get("properties", {})
    for key in schema.get("required", []):
        if key not in arguments:
            return f"缺少必填参数：{key}"
    for key, value in arguments.items():
        if key not in properties:
            return f"未知参数：{key}"
        expected = properties[key].get("type")
        if expected == "integer":
            if isinstance(value, bool) or not isinstance(value, int):
                return f"参数 {key} 需要整数"
        elif expected == "boolean":
            if not isinstance(value, bool):
                return f"参数 {key} 需要布尔值"
        elif expected == "string" and not isinstance(value, str):
            return f"参数 {key} 需要字符串"
    return None


def _repo_root():
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _resolve_cli():
    candidates = []
    configured = os.environ.get("VOICEOS_CLI", "").strip()
    if configured:
        candidates.append(os.path.expanduser(configured))
    candidates.append(os.path.expanduser("~/.local/bin/voiceos-cli"))
    candidates.append(os.path.join(_repo_root(), ".build", "release", "voiceos-cli"))
    on_path = shutil.which("voiceos-cli")
    if on_path:
        candidates.append(on_path)
    for candidate in candidates:
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def _run_cli(args):
    cli = _resolve_cli()
    if cli is None:
        return True, ("未找到 voiceos-cli。查找顺序：$VOICEOS_CLI、~/.local/bin/voiceos-cli、"
                      "仓库 .build/release/voiceos-cli、PATH。先运行 "
                      "swift build --product voiceos-cli。")
    try:
        completed = subprocess.run(
            [cli, *args],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=CLI_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        return True, f"voiceos-cli 超时（{CLI_TIMEOUT_SECONDS} 秒）。写命令内部最多轮询 10 秒。"
    except OSError as error:
        return True, f"无法启动 voiceos-cli：{error}"
    if completed.returncode == 0:
        return False, completed.stdout
    detail = completed.stderr.strip() or f"voiceos-cli 退出码 {completed.returncode}"
    return True, detail


def _handle(request):
    method = request.get("method")
    if not isinstance(method, str):
        raise RpcError(-32600, "缺少 method")
    params = request.get("params")
    if params is None:
        params = {}
    if method == "initialize":
        if not isinstance(params, dict):
            raise RpcError(-32602, "params 必须是对象")
        requested = params.get("protocolVersion")
        version = requested if requested in PROTOCOL_VERSIONS else DEFAULT_PROTOCOL_VERSION
        return {"protocolVersion": version, "capabilities": {"tools": {}},
                "serverInfo": SERVER_INFO}
    if method == "ping":
        return {}
    if method == "tools/list":
        return {"tools": [
            {"name": name, "description": spec["description"], "inputSchema": spec["inputSchema"]}
            for name, spec in TOOLS.items()
        ]}
    if method == "tools/call":
        if not isinstance(params, dict):
            raise RpcError(-32602, "params 必须是对象")
        name = params.get("name")
        spec = TOOLS.get(name)
        if spec is None:
            raise RpcError(-32602, f"未知工具：{name}")
        arguments = params.get("arguments", {})
        problem = _validate(spec["inputSchema"], arguments)
        if problem is not None:
            raise RpcError(-32602, problem)
        is_error, text = _run_cli(spec["build_args"](arguments))
        return {"content": [{"type": "text", "text": text}], "isError": is_error}
    raise RpcError(-32601, f"未知方法：{method}")


def _write(payload):
    data = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.buffer.write(data.encode("utf-8") + b"\n")
    sys.stdout.buffer.flush()


def _error(request_id, code, message):
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


def main():
    for raw in sys.stdin.buffer:
        line = raw.decode("utf-8", errors="replace").strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            _write(_error(None, -32700, "JSON 解析失败"))
            continue
        if not isinstance(message, dict):
            _write(_error(None, -32600, "请求必须是 JSON 对象"))
            continue
        if "id" not in message:
            continue
        request_id = message["id"]
        try:
            result = _handle(message)
        except RpcError as error:
            _write(_error(request_id, error.code, error.message))
            continue
        except Exception as error:
            _write(_error(request_id, -32603, f"内部错误：{error}"))
            continue
        _write({"jsonrpc": "2.0", "id": request_id, "result": result})


if __name__ == "__main__":
    main()