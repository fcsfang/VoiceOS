#!/usr/bin/env python3

import json
import os
import select
import shutil
import subprocess
import sys
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "server.py")
REPO = os.path.dirname(os.path.dirname(HERE))
MISSING_ID = "00000000-0000-0000-0000-000000000000"


def find_cli():
    configured = os.environ.get("VOICEOS_CLI", "").strip()
    if configured:
        return os.path.expanduser(configured)
    for candidate in (
        os.path.join(REPO, ".build", "debug", "voiceos-cli"),
        os.path.join(REPO, ".build", "release", "voiceos-cli"),
    ):
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return shutil.which("voiceos-cli")


CLI = find_cli()
CLI_SUPPORTS_FEEDBACK = False
if CLI is not None:
    probe = subprocess.run([CLI, "--help"], capture_output=True, text=True)
    CLI_SUPPORTS_FEEDBACK = "action feedback" in probe.stdout


class Server:
    def __init__(self):
        env = dict(os.environ)
        if CLI is not None:
            env["VOICEOS_CLI"] = CLI
        self.proc = subprocess.Popen(
            [sys.executable, SERVER],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=env,
        )
        self._next_id = 1

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def request(self, method, params=None):
        request_id = self._next_id
        self._next_id += 1
        payload = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            payload["params"] = params
        self.send(payload)
        return self.read_response(request_id)

    def send(self, payload):
        self.send_raw(json.dumps(payload))

    def send_raw(self, text):
        self.proc.stdin.write(text + "\n")
        self.proc.stdin.flush()

    def read_response(self, request_id, timeout=45):
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError(f"等待响应超时：id={request_id!r}")
            ready, _, _ = select.select([self.proc.stdout], [], [], remaining)
            if not ready:
                continue
            line = self.proc.stdout.readline()
            if line == "":
                raise AssertionError(f"服务端关闭 stdout；退出码 {self.proc.poll()}")
            message = json.loads(line)
            if message.get("id") == request_id:
                return message

    def close(self):
        if self.proc.poll() is None:
            try:
                self.proc.stdin.close()
            except OSError:
                pass
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        stderr = self.proc.stderr.read()
        self.proc.stderr.close()
        self.proc.stdout.close()
        return stderr


def initialize_params(version):
    return {
        "protocolVersion": version,
        "capabilities": {},
        "clientInfo": {"name": "voiceos-mcp-test", "version": "0.0.1"},
    }


class ServerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if CLI is None:
            raise RuntimeError(
                "未找到 voiceos-cli；先运行 swift build --product voiceos-cli"
            )
        cls.server = Server()
        cls.initialize = cls.server.request("initialize", initialize_params("2025-06-18"))
        cls.server.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    @classmethod
    def tearDownClass(cls):
        stderr = cls.server.close()
        assert stderr == "", f"服务端不应写 stderr：{stderr}"

    def call(self, name, arguments):
        response = self.server.request("tools/call", {"name": name, "arguments": arguments})
        self.assertNotIn("error", response)
        return response["result"]

    def test_01_initialize(self):
        result = self.initialize["result"]
        self.assertEqual(result["protocolVersion"], "2025-06-18")
        self.assertIn("tools", result["capabilities"])
        self.assertEqual(result["serverInfo"]["name"], "voiceos")

    def test_02_protocol_version_negotiation(self):
        with Server() as server:
            response = server.request("initialize", initialize_params("2024-11-05"))
            self.assertEqual(response["result"]["protocolVersion"], "2024-11-05")
        with Server() as server:
            response = server.request("initialize", initialize_params("1999-01-01"))
            self.assertEqual(response["result"]["protocolVersion"], "2025-06-18")

    def test_03_tools_list(self):
        tools = self.server.request("tools/list")["result"]["tools"]
        by_name = {tool["name"]: tool for tool in tools}
        self.assertEqual(set(by_name), {
            "voiceos_actions_list",
            "voiceos_actions_show",
            "voiceos_status",
            "voiceos_action_feedback",
            "voiceos_action_complete",
        })
        required = {
            "voiceos_actions_list": set(),
            "voiceos_actions_show": {"id"},
            "voiceos_status": set(),
            "voiceos_action_feedback": {"id", "text"},
            "voiceos_action_complete": {"id"},
        }
        for name, tool in by_name.items():
            schema = tool["inputSchema"]
            self.assertEqual(schema["type"], "object", name)
            self.assertFalse(schema["additionalProperties"], name)
            self.assertEqual(set(schema["required"]), required[name], name)
            self.assertTrue(tool["description"], name)
        list_properties = by_name["voiceos_actions_list"]["inputSchema"]["properties"]
        self.assertEqual(set(list_properties), {"state", "validity", "kind", "limit", "offset"})

    def test_04_status(self):
        result = self.call("voiceos_status", {})
        self.assertFalse(result["isError"])
        data = json.loads(result["content"][0]["text"])
        self.assertIn("userVersion", data)
        self.assertIn("actionsOpen", data)

    def test_05_actions_list_limit(self):
        result = self.call("voiceos_actions_list", {"limit": 1})
        self.assertFalse(result["isError"])
        data = json.loads(result["content"][0]["text"])
        self.assertIsInstance(data["actions"], list)
        self.assertLessEqual(len(data["actions"]), 1)
        self.assertEqual(data["count"], len(data["actions"]))

    def test_06_missing_action_is_error(self):
        result = self.call("voiceos_actions_show", {"id": MISSING_ID})
        self.assertTrue(result["isError"])
        error = json.loads(result["content"][0]["text"])
        self.assertEqual(error["error"]["code"], "not_found")

    def test_07_feedback_requires_text(self):
        response = self.server.request(
            "tools/call", {"name": "voiceos_action_feedback", "arguments": {"id": MISSING_ID}}
        )
        self.assertEqual(response["error"]["code"], -32602)
        self.assertIn("text", response["error"]["message"])

    def test_08_feedback_invalid_kind_reaches_cli(self):
        if not CLI_SUPPORTS_FEEDBACK:
            self.skipTest("当前 voiceos-cli 不含 action feedback；使用分支构建")
        result = self.call(
            "voiceos_action_feedback",
            {"id": MISSING_ID, "text": "参数校验路径", "kind": "bogus"},
        )
        self.assertTrue(result["isError"])
        self.assertIn("--kind", result["content"][0]["text"])

    def test_09_unknown_parameter_rejected(self):
        response = self.server.request(
            "tools/call", {"name": "voiceos_actions_list", "arguments": {"topics": True}}
        )
        self.assertEqual(response["error"]["code"], -32602)
        self.assertIn("topics", response["error"]["message"])

    def test_10_unknown_tool(self):
        response = self.server.request(
            "tools/call", {"name": "voiceos_missing", "arguments": {}}
        )
        self.assertEqual(response["error"]["code"], -32602)

    def test_11_unknown_method(self):
        response = self.server.request("voiceos/missing", {})
        self.assertEqual(response["error"]["code"], -32601)

    def test_12_parse_error(self):
        self.server.send_raw("{not json")
        response = self.server.read_response(None)
        self.assertEqual(response["error"]["code"], -32700)
        self.assertIsNone(response["id"])

    def test_13_ping(self):
        response = self.server.request("ping")
        self.assertEqual(response["result"], {})


if __name__ == "__main__":
    unittest.main(verbosity=2)