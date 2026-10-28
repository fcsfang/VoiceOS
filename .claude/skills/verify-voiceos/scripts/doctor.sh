#!/usr/bin/env bash
set -euo pipefail

DATA=${1:?usage: doctor.sh <data-dir> [pid]}
PID=${2:-}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
BIN="$ROOT/.build/debug/voiceos-check"

[ -d "$DATA" ] || { echo "doctor: data dir missing: $DATA" >&2; exit 1; }
[ -x "$BIN" ] || { echo "doctor: missing $BIN; run: swift build --product voiceos-check -j 4" >&2; exit 1; }

if [ -n "$PID" ]; then
  kill -0 "$PID" 2>/dev/null || { echo "doctor: app pid $PID is not running" >&2; exit 1; }
  COMMAND=$(ps -p "$PID" -o command=)
  case "$COMMAND" in
    *"dist/VoiceOS.app/Contents/MacOS/VoiceOS"*) ;;
    *) echo "doctor: pid $PID is not the VoiceOS app: $COMMAND" >&2; exit 1 ;;
  esac
  echo "doctor: app pid $PID alive"
fi

"$BIN" read "$DATA" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("integrity") is True else 1)' \
  || { echo "doctor: library integrity failed" >&2; exit 1; }
echo "doctor: library integrity ok"

if osascript -e 'tell application "System Events" to tell process "VoiceOS" to get name of windows' >/dev/null 2>&1; then
  echo "gui: accessible"
else
  echo "gui: blocked (System Settings > Privacy & Security > Accessibility > host app)"
fi

SHOT=$(mktemp /tmp/voiceos-doctor.XXXXXX.png)
if screencapture -x "$SHOT" >/dev/null 2>&1; then
  echo "screen: accessible"
else
  echo "screen: blocked (System Settings > Privacy & Security > Screen Recording)"
fi
rm -f "$SHOT"
