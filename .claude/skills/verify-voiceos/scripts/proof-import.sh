#!/usr/bin/env bash
set -euo pipefail

DATA=${1:?usage: proof-import.sh <data-dir> <fixture.wav> <evidence-dir>}
FIXTURE=${2:?usage: proof-import.sh <data-dir> <fixture.wav> <evidence-dir>}
EVIDENCE=${3:?usage: proof-import.sh <data-dir> <fixture.wav> <evidence-dir>}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
BIN="$ROOT/.build/debug/voiceos-check"
COMMAND="verify-import-$(date -u +%Y%m%dT%H%M%SZ)"

[ -f "$FIXTURE" ] || { echo "proof: fixture missing: $FIXTURE" >&2; exit 1; }
mkdir -p "$DATA" "$EVIDENCE"
rm -rf "$EVIDENCE/export" "$EVIDENCE/restore"
: > "$EVIDENCE/commands.log"

run() { echo "+ $*" >> "$EVIDENCE/commands.log"; "$@"; }

if [ ! -x "$BIN" ]; then
  echo "proof: building voiceos-check" | tee -a "$EVIDENCE/commands.log"
  (cd "$ROOT" && swift build --product voiceos-check -j 4)
fi

run "$BIN" import "$DATA" "$FIXTURE" "$COMMAND" > "$EVIDENCE/first.json"
run "$BIN" import "$DATA" "$FIXTURE" "$COMMAND" > "$EVIDENCE/second.json"
run "$BIN" read "$DATA" > "$EVIDENCE/read.json"

python3 - "$EVIDENCE/first.json" "$EVIDENCE/second.json" "$EVIDENCE/read.json" <<'PY'
import json, sys
first, second, read = (json.load(open(p)) for p in sys.argv[1:4])
for name, doc in (("first", first), ("second", second), ("read", read)):
    assert doc.get("integrity") is True, f"{name}: integrity failed"
    assert len(doc.get("records", [])) == 1, f"{name}: expected one source, got {len(doc.get('records', []))}"
a, b, c = first["records"][0], second["records"][0], read["records"][0]
assert a["id"] == b["id"] == c["id"], "re-delivered command created a second source"
assert a["state"] == "saved", f"expected saved, got {a['state']}"
assert a["job_state"] == "queued", f"expected queued transcription, got {a['job_state']}"
print("assert: duplicate command reused one saved source")
PY

sqlite3 "$DATA/voiceos.sqlite" ".backup '$EVIDENCE/db-backup.sqlite'"
sqlite3 "$DATA/voiceos.sqlite" "SELECT id,state,(SELECT state FROM jobs WHERE source_id=sources.id) FROM sources;" > "$EVIDENCE/sources.txt"

run "$BIN" export "$DATA" "$EVIDENCE/export" media > "$EVIDENCE/export.json"
run "$BIN" restore "$EVIDENCE/restore" "$EVIDENCE/export" > "$EVIDENCE/restore.json"
run "$BIN" read "$EVIDENCE/restore" > "$EVIDENCE/restored.json"

python3 - "$EVIDENCE/read.json" "$EVIDENCE/restored.json" <<'PY'
import json, sys
original, restored = (json.load(open(p)) for p in sys.argv[1:3])
assert restored.get("integrity") is True, "restored: integrity failed"
a = original["records"][0]
b = restored["records"][0]
assert a["id"] == b["id"], "restore changed the source identity"
assert b["state"] == "saved", f"restored with media should be saved, got {b['state']}"
print("assert: media restore kept identity and saved state")
PY

find "$DATA/assets" "$EVIDENCE/restore/assets" -maxdepth 1 -type f -exec shasum -a 256 {} \; \
  | sed "s#$ROOT#ROOT#g" > "$EVIDENCE/sha256.txt"
ORIGINAL_HASH=$(find "$DATA/assets" -maxdepth 1 -type f -exec shasum -a 256 {} \; | awk '{print $1}' | sort)
RESTORED_HASH=$(find "$EVIDENCE/restore/assets" -maxdepth 1 -type f -exec shasum -a 256 {} \; | awk '{print $1}' | sort)
[ -n "$ORIGINAL_HASH" ] || { echo "proof: original asset missing" >&2; exit 1; }
[ "$ORIGINAL_HASH" = "$RESTORED_HASH" ] || { echo "proof: restored asset hash differs" >&2; exit 1; }

echo "proof: ok" | tee -a "$EVIDENCE/proof.txt"
