---
name: verify-voiceos
description: Drive the real VoiceOS macOS app and its voiceos-check CLI to prove recording import, dictation, expression saving, and export/restore behavior. Use when a change touches recording capture, the library store, the SwiftUI control center, or package migration.
---

# Verify VoiceOS

VoiceOS has two user-facing surfaces:

- the macOS SwiftUI app (`dist/VoiceOS.app`), driven by `scripts/app/run.py`;
- the `voiceos-check` CLI, which opens the same `VoiceOSStore` and media inspector without a model call.

The CLI surface is the default proof path because it runs without Accessibility permission and exercises the real store, real AVFoundation inspection, real hashing, and real package export/restore. The GUI surface is documented for changes that only a click can prove; it needs macOS Accessibility permission for the host app (Claude or Terminal).

## Launch

Build the app once if `dist/VoiceOS.app` is missing. `--adhoc` is a disposable build; privacy grants may not survive a rebuild.

```bash
python3 scripts/app/build.py --adhoc
```

Start a throwaway instance against an isolated library. `run.py` execs the app, so `$!` is the app PID.

```bash
ROOT="/Users/joey/01 Projects/VoiceOS"
DATA_GUI=$(mktemp -d /tmp/voiceos-gui.XXXXXX)
python3 "$ROOT/scripts/app/run.py" --data-dir "$DATA_GUI" &
APP_PID=$!
```

Ready means the process is alive, the window is up, and `voiceos-check read` reports `"integrity": true` for the same data dir. The store creates `voiceos.sqlite`, `assets/`, and `staging/` under `$DATA_GUI`.

Do not share a data dir between the running app and a CLI proof: `VoiceOSStore` takes an exclusive `store.lock`. Use `$DATA_GUI` for the app and a separate `$DATA_CLI` for CLI proofs.

## Doctor

Run this first whenever a step looks wrong. It is read-only.

```bash
.claude/skills/verify-voiceos/scripts/doctor.sh "$DATA_GUI" "$APP_PID"
```

It checks the PID is the `dist/VoiceOS.app` executable, `voiceos-check read` reports integrity, and whether GUI scripting is allowed. GUI output is advisory: `gui: blocked` means grant Accessibility to the host app in System Settings → Privacy & Security → Accessibility; CLI proofs still work.

## Drive

### CLI proof (verified, default)

```bash
DATA_CLI=$(mktemp -d /tmp/voiceos-cli.XXXXXX)
FIXTURE=/tmp/voiceos-fixture.wav
EVIDENCE="$ROOT/.claude/skills/verify-voiceos/evidence/$(date -u +%Y%m%dT%H%M%SZ)"
python3 "$ROOT/.claude/skills/verify-voiceos/scripts/make-fixture.py" "$FIXTURE"
.claude/skills/verify-voiceos/scripts/proof-import.sh "$DATA_CLI" "$FIXTURE" "$EVIDENCE"
```

The proof imports the same file twice with one command ID, asserts one source row and the same source ID, reads the library, exports with media, restores into a new library, and asserts the restored asset hash and `saved` state. It writes every observation under `$EVIDENCE` and never shares a store with the GUI instance.

### GUI proof (needs Accessibility)

The app exposes stable Chinese button labels. With Accessibility granted to the host app:

```bash
osascript <<'APPLESCRIPT'
tell application "System Events"
  tell process "VoiceOS"
    set frontmost to true
    click button "记录我的表达" of window "VoiceOS"
    delay 0.5
    set value of text area 1 of sheet 1 of window "VoiceOS" to "验证用表达：这是一条只保存在本机的原文。"
    click button "保存表达" of sheet 1 of window "VoiceOS"
  end tell
end tell
APPLESCRIPT
```

If `sheet 1` is not the dialog on this macOS version, inspect `entire contents of window "VoiceOS"` once and adjust the path. Always target the window of the isolated instance; a second VoiceOS instance may belong to the user.

For dictation, the menu is `开始我的口述` and the capture hook is `VOICEOS_TEST_CAPTURE_SECONDS`, which `run.py --capture-limit-seconds` sets and requires `--data-dir`. It records for the given duration and does not start a model review. Microphone permission is still required.

## Evidence

The proof artifact directory is the `$EVIDENCE` path above (gitignored). A complete proof contains:

- `first.json` and `second.json` from the duplicate import commands;
- `read.json` for the original library and `restored.json` for the restored library;
- `db-backup.sqlite` made with `sqlite3 … ".backup"`, safe while WAL is active;
- `sha256.txt` for the original and restored assets;
- `proof.txt` with the final assertions.

Proof standards: drive the real user path (`voiceos-check import` / the SwiftUI button), capture the action and the resulting state, and verify side effects (asset file, hash, database row, job state), not only the final screen. Do not replace the media inspector or the store with a mock. Model and reminder ports may be simulated only where the product already isolates an external system; the CLI import path never calls a model.

## Cleanup

Kill only the PID you started. Never `pkill VoiceOS`: the user may have their own instance open.

```bash
kill "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true
rm -rf "$DATA_GUI" "$DATA_CLI"
```

Remove scratch libraries after the evidence is copied. Evidence survives cleanup.

## Helpers

- `scripts/make-fixture.py <out.wav>` — 1 s mono 16-bit 44.1 kHz silence, enough for the real media inspector.
- `scripts/doctor.sh <data-dir> [pid]` — read-only health check and GUI permission probe.
- `scripts/proof-import.sh <data-dir> <fixture.wav> <evidence-dir>` — import/duplicate/read/export/restore proof with assertions.

## Feature map

Start with [features/README.md](features/README.md). Each feature file names the observable end state and the exact drive recipe.
