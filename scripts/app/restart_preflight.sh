#!/bin/bash
# 重启 VoiceOS 前的前置检查：用户空闲 ≥120 秒，且没有会因退出而丢失结果的后台工作。
# 用法：scripts/app/restart_preflight.sh && pkill -TERM -x VoiceOS && open dist/VoiceOS.app
set -uo pipefail
DB="${VOICEOS_DB:-$HOME/Library/Application Support/VoiceOS/voiceos.sqlite}"
idle_ns=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print $NF; exit}')
idle_s=$(( ${idle_ns:-0} / 1000000000 ))
count() { sqlite3 -readonly "$DB" "$1" 2>/dev/null || echo 0; }
assist=$(count "SELECT COUNT(*) FROM assistant_executions WHERE state IN ('queued','running') AND validity='current';")
know=$(count "SELECT COUNT(*) FROM knowledge_reviews WHERE state='running';")
busy=$(( assist + know ))
if [ "$idle_s" -lt 120 ] || [ "$busy" -gt 0 ]; then
  echo "busy idle=${idle_s}s assistant=${assist} knowledge=${know}"
  exit 1
fi
echo "safe idle=${idle_s}s"
