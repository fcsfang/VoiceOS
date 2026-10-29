# Export and restore a library

## Sub-features

- Export structured records without media (`voiceos-check export <library> <dir>`).
- Export records and original assets (`voiceos-check export <library> <dir> media`).
- Restore into a new library (`voiceos-check restore <new-library> <package-dir>`), with a package summary and integrity preflight.
- Restore a no-media package: structure and text return, assets are explicitly absent and sources become `reference_only`.

## How to get to it (user POV)

In the app: `导出资料` → `导出结构化资料…` or `导出资料与原件…`. Restore from the app's migration dialog, or headlessly with `voiceos-check restore`.

## Driving it with `voiceos-check`

```bash
ROOT="/Users/joey/01 Projects/VoiceOS"
DATA=$(mktemp -d /tmp/voiceos-export.XXXXXX)
FIXTURE=/tmp/voiceos-fixture.wav
EVIDENCE=$(mktemp -d /tmp/voiceos-evidence.XXXXXX)
python3 "$ROOT/.claude/skills/verify-voiceos/scripts/make-fixture.py" "$FIXTURE"
"$ROOT/.build/debug/voiceos-check" import "$DATA" "$FIXTURE" verify-export-1
"$ROOT/.build/debug/voiceos-check" export "$DATA" "$EVIDENCE/export" media
"$ROOT/.build/debug/voiceos-check" restore "$EVIDENCE/restore" "$EVIDENCE/export"
"$ROOT/.build/debug/voiceos-check" read "$EVIDENCE/restore"
```

Observable end state: `restore` prints `{"restored":true}`; the restored library reports `integrity: true`, the same source ID, `state=saved`, and an asset file whose SHA-256 equals the original. A no-media export restores with `state=reference_only` and no asset file.

## Gotchas

- The restore target must be a new directory; the code refuses to restore over an existing library.
- Restoring does not reconnect Apple Reminders. That is an explicit product boundary, not a restore failure.
- A package that claims media but lacks a file fails preflight; an explicitly no-media package is valid and restores structure only.
- `scripts/proof-import.sh` performs this flow with assertions and also proves command-id idempotency.

## Proven in this checkout

Both media and no-media export/restore were run against a fresh library. Media restore kept the source ID, the asset SHA-256, and `saved`; no-media restore produced `reference_only` with `integrity: true`.
