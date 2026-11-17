#!/usr/bin/env python3
"""Read one exact QQ group time range as JSON for VoiceOS daily monitoring."""
import json
import os
import sys

os.umask(0o077)

CHATLAB_KINDS = {
    0: "text",
    5: "text",
    25: "text",
    1: "image",
    4: "file",
    24: "article",
}


def fail(code, zh, en):
    sys.stderr.write(json.dumps({"version": 1, "error": {"code": code, "zh": zh, "en": en}}, ensure_ascii=False) + "\n")
    sys.exit(2)


def main():
    raw = sys.stdin.read(4_000_000)
    try:
        request = json.loads(raw)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        fail("invalid_input", "读取参数不是有效 JSON", f"{type(exc).__name__}: {exc}")
    if not isinstance(request, dict) or request.get("version") != 1:
        fail("invalid_input", "读取参数版本不受支持", "request version must be 1")
    key_path = request.get("key_path")
    cache_dir = request.get("cache_dir")
    conversation_id = request.get("conversation_id")
    start_text = request.get("start_iso8601")
    end_text = request.get("end_iso8601")
    account = request.get("account") or None
    if not isinstance(key_path, str) or not key_path or not isinstance(cache_dir, str) or not cache_dir:
        fail("invalid_input", "读取参数缺少密钥路径或缓存目录", "key_path and cache_dir are required")
    if not isinstance(conversation_id, str) or ":" not in conversation_id:
        fail("invalid_input", "读取参数缺少会话标识", "conversation_id looks like group:123")
    if not isinstance(start_text, str) or not isinstance(end_text, str):
        fail("invalid_input", "读取参数缺少时间区间", "start_iso8601 and end_iso8601 are required")

    from datetime import datetime

    try:
        start = datetime.fromisoformat(start_text)
        end = datetime.fromisoformat(end_text)
    except ValueError as exc:
        fail("range_invalid", "时间区间无法解析", f"{type(exc).__name__}: {exc}")
    if start.tzinfo is None or end.tzinfo is None or start >= end:
        fail("range_invalid", "时间区间必须包含时区且开始早于结束", "range must be timezone-aware and start < end")

    try:
        from qqnt_export_macos.recent import QQRecentReader
        from qqnt_export_macos.chatlab import export_chatlab_range
    except Exception as exc:
        fail("import_failed", "无法导入 qqnt-export-macos：请在该 Python 解释器中安装该库",
             f"python import failed: {type(exc).__name__}: {exc}")

    from pathlib import Path

    key_file = Path(key_path).expanduser()
    if not key_file.is_file() or key_file.stat().st_size == 0:
        fail("key_invalid", "密钥文件缺失或为空", f"key file unavailable: {key_file}")
    try:
        reader = QQRecentReader(key_file, cache_dir=Path(cache_dir).expanduser(), account=account)
        payload = export_chatlab_range(reader, range_start=start, range_end=end, conversation_id=conversation_id)
    except FileNotFoundError as exc:
        fail("qq_data_missing", "未找到该账号的 QQ 数据目录", f"{type(exc).__name__}: {exc}")
    except PermissionError as exc:
        fail("key_invalid", "密钥或 QQ 数据无法读取", f"{type(exc).__name__}: {exc}")
    except ValueError as exc:
        fail("read_failed", "QQ 数据读取失败", f"ValueError: {exc}")
    except Exception as exc:
        fail("read_failed", "QQ 数据读取失败", f"{type(exc).__name__}: {exc}")

    messages = []
    for message in payload.get("messages", []):
        chatlab_type = message.get("type")
        meta = {}
        for key in ("contentMetadata", "replyToMessageId", "replyContext"):
            value = message.get(key)
            if value not in (None, {}, [], ""):
                meta[key] = value
        meta["chatlab_type"] = chatlab_type
        messages.append({
            "message_id": str(message.get("platformMessageId", "")),
            "timestamp_ms": int(message.get("timestamp") or 0),
            "sender_name": message.get("groupNickname") or message.get("accountName") or message.get("sender"),
            "sender_id": message.get("sender"),
            "type": CHATLAB_KINDS.get(chatlab_type, "other"),
            "text": message.get("content") or "",
            "meta": meta,
        })

    name = (payload.get("meta") or {}).get("name")
    result = {
        "version": 1,
        "conversation_id": conversation_id,
        "conversation_name": name,
        "range": {"start": start.isoformat(), "end": end.isoformat()},
        "message_count": len(messages),
        "messages": messages,
        "truncated": False,
    }
    sys.stdout.write(json.dumps(result, ensure_ascii=False) + "\n")
    sys.stdout.flush()


if __name__ == "__main__":
    main()
