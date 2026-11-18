#!/usr/bin/env python3
"""Read one exact QQ group time range, or list groups, as JSON for VoiceOS."""
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


def emit(result):
    sys.stdout.write(json.dumps(result, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def parse_request():
    raw = sys.stdin.read(4_000_000)
    try:
        request = json.loads(raw)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        fail("invalid_input", "读取参数不是有效 JSON", f"{type(exc).__name__}: {exc}")
    if not isinstance(request, dict) or request.get("version") != 1:
        fail("invalid_input", "读取参数版本不受支持", "request version must be 1")
    return request


def key_and_cache(request):
    key_path = request.get("key_path")
    cache_dir = request.get("cache_dir")
    if not isinstance(key_path, str) or not key_path or not isinstance(cache_dir, str) or not cache_dir:
        fail("invalid_input", "读取参数缺少密钥路径或缓存目录", "key_path and cache_dir are required")
    return key_path, cache_dir


def import_reader():
    try:
        from qqnt_export_macos.recent import QQRecentReader
    except Exception as exc:
        fail("import_failed", "无法导入 qqnt-export-macos：请在该 Python 解释器中安装该库",
             f"python import failed: {type(exc).__name__}: {exc}")
    return QQRecentReader


def reader_for(key_path, cache_dir, account, reader_cls):
    from pathlib import Path

    key_file = Path(key_path).expanduser()
    if not key_file.is_file() or key_file.stat().st_size == 0:
        fail("key_invalid", "密钥文件缺失或为空", f"key file unavailable: {key_file}")
    return reader_cls(key_file, cache_dir=Path(cache_dir).expanduser(), account=account)


FULL_DISK_ACCESS_ZH = (
    "需要完全磁盘访问权限：请打开 系统设置 → 隐私与安全性 → 完全磁盘访问权限，"
    "勾选 VoiceOS，然后完全退出并重新打开 VoiceOS；若刚更新过应用，可能需要重新授权"
)


def read_failure(exc):
    if isinstance(exc, FileNotFoundError):
        fail("qq_data_missing", "未找到该账号的 QQ 数据目录", f"{type(exc).__name__}: {exc}")
    detail = f"{type(exc).__name__}: {exc}"
    if isinstance(exc, PermissionError) or "Operation not permitted" in detail:
        fail("permission_denied", FULL_DISK_ACCESS_ZH, detail)
    fail("read_failed", "QQ 数据读取失败", detail)


def conversations(request, reader_cls):
    key_path, cache_dir = key_and_cache(request)
    account = request.get("account") or None
    query = request.get("query") or ""
    try:
        minutes = int(request.get("minutes") or 365 * 24 * 60)
        limit = int(request.get("limit") or 100)
    except (TypeError, ValueError):
        fail("invalid_input", "列群参数无效", "minutes and limit must be integers")
    minutes = max(1, min(minutes, 525600))
    limit = max(1, min(limit, 100))
    if not isinstance(query, str):
        query = ""
    try:
        reader = reader_for(key_path, cache_dir, account, reader_cls)
        payload = reader.find_conversations(query, minutes=minutes, limit=limit)
    except Exception as exc:
        read_failure(exc)
    rows = []
    for item in payload.get("matches", []):
        conversation_id = str(item.get("conversation_id") or "")
        if not conversation_id.startswith("group:"):
            continue
        latest = int(item.get("latest_timestamp") or 0)
        rows.append({
            "conversation_id": conversation_id,
            "conversation_name": item.get("conversation_name"),
            "kind": "group",
            "latest_timestamp": latest,
            "latest_time": item.get("latest_time"),
            "message_count": int(item.get("message_count") or 0),
        })
    rows.sort(key=lambda row: (-row["latest_timestamp"], str(row["conversation_name"] or ""), row["conversation_id"]))
    rows = rows[:limit]
    emit({"version": 1, "action": "conversations", "count": len(rows), "conversations": rows})


def read_range(request):
    key_path, cache_dir = key_and_cache(request)
    conversation_id = request.get("conversation_id")
    start_text = request.get("start_iso8601")
    end_text = request.get("end_iso8601")
    account = request.get("account") or None
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

    reader_cls = import_reader()
    try:
        from qqnt_export_macos.chatlab import export_chatlab_range
    except Exception as exc:
        fail("import_failed", "无法导入 qqnt-export-macos：请在该 Python 解释器中安装该库",
             f"python import failed: {type(exc).__name__}: {exc}")

    try:
        reader = reader_for(key_path, cache_dir, account, reader_cls)
        payload = export_chatlab_range(reader, range_start=start, range_end=end, conversation_id=conversation_id)
    except Exception as exc:
        read_failure(exc)

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
    emit({
        "version": 1,
        "conversation_id": conversation_id,
        "conversation_name": name,
        "range": {"start": start.isoformat(), "end": end.isoformat()},
        "message_count": len(messages),
        "messages": messages,
        "truncated": False,
    })


def main():
    request = parse_request()
    action = request.get("action") or "read"
    if action == "conversations":
        conversations(request, import_reader())
        return
    if action != "read":
        fail("invalid_input", "读取参数的操作类型不受支持", "action must be read or conversations")
    read_range(request)


if __name__ == "__main__":
    main()
