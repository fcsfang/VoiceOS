# Import a recording

## Sub-features

- External audio or video import (`voiceos-check import`, menu 导入文件 → 外部音频或视频…).
- Personal-audio import (`voiceos-check import-personal-audio`, menu 导入文件 → 仅含我声音的录音…), which grants attribution but not cloud processing.
- Command-id re-delivery: the same command ID and the same file return the existing source; a different file under the same command ID is rejected.
- Integrity failure: a zero-byte or changing file is rejected; a stored asset that later fails hashing is quarantined.

## How to get to it (user POV)

In the app: 导入文件 → 外部音频或视频…, choose a file, then watch the source appear with a queued transcription. From a shell: `voiceos-check import <library> <file> [command-id]` performs the same store import without the UI.

## Driving it with `voiceos-check`

```bash
ROOT="/Users/joey/01 Projects/VoiceOS"
DATA=$(mktemp -d /tmp/voiceos-import.XXXXXX)
FIXTURE=/tmp/voiceos-fixture.wav
python3 "$ROOT/.claude/skills/verify-voiceos/scripts/make-fixture.py" "$FIXTURE"
"$ROOT/.build/debug/voiceos-check" import "$DATA" "$FIXTURE" verify-import-1
"$ROOT/.build/debug/voiceos-check" import "$DATA" "$FIXTURE" verify-import-1
"$ROOT/.build/debug/voiceos-check" read "$DATA"
```

Observable end state: `integrity: true`, exactly one source, `state: saved`, `job_state: queued`, one file under `assets/` whose SHA-256 equals the fixture copy recorded by the store. The second import must print the same source ID. `scripts/proof-import.sh` automates this and also proves media export/restore.

## Gotchas

- The app holds an exclusive `store.lock`; run the CLI proof on a data dir the app is not using.
- The import copies and hashes the file. If the source changes during the copy, the import fails rather than saving a mixed file.
- A successful import only queues transcription. Without a configured Qwen speech port the job stays `queued`; that is expected and is not a failed import.
- `import-personal-audio` accepts audio extensions only and records `origin=user`, `speaker=user`; it does not grant cloud permission.
- A no-media export restores structure only; the restored source is `reference_only`, not `saved`. See [export-restore.md](export-restore.md).

## Proven in this checkout

The CLI recipe above was run end to end against a fresh library: duplicate import reused one ID, the asset hash matched, media export/restore preserved the ID and `saved` state, and `integrity: true`.
