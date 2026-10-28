# Record and seal dictation

## Sub-features

- Start and stop a personal dictation (`开始我的口述` → `录制并本地保存`).
- Seal only after the device stops and the file hashes, decodes, and is moved into `assets/`.
- Interrupted capture: a system interruption keeps the fragment as `interrupted`, never as a complete `saved` recording.
- Timed capture for verification (`VOICEOS_TEST_CAPTURE_SECONDS`, set by `run.py --capture-limit-seconds`, 0–60 s, requires an isolated `--data-dir`).

## How to get to it (user POV)

In the app: click `开始我的口述`, choose `录制并本地保存`, speak, then click `停止并保存口述`. The status line reports sealing, and the source appears in the library.

## Driving it with SwiftUI + `voiceos-check`

GUI drive needs macOS Accessibility permission for the host app and microphone permission for VoiceOS. Launch an isolated instance:

```bash
ROOT="/Users/joey/01 Projects/VoiceOS"
DATA=$(mktemp -d /tmp/voiceos-dictation.XXXXXX)
python3 "$ROOT/scripts/app/run.py" --data-dir "$DATA" --capture-limit-seconds 1 &
APP_PID=$!
```

Click the menu with System Events, or use the capture limit to stop the device without a second click. Then inspect the store:

```bash
"$ROOT/.build/debug/voiceos-check" read "$DATA"
sqlite3 "$DATA/voiceos.sqlite" "SELECT state,expected_bytes,expected_hash,relative_path FROM sources;"
```

Observable end state after a successful seal: `state=saved`, a positive `expected_bytes`, a 64-hex `expected_hash`, and the file at `assets/<asset>.caf`. `voiceos-check read` reports `integrity: true`.

## Gotchas

- `startDictation` refuses a second capture while one is `receiving`; finish or interrupt the first.
- A failed seal keeps the fragment `interrupted` and the UI must not say saved. Do not "fix" a test by promoting it.
- The test capture path only changes duration; it does not bypass microphone permission or the seal check.
- The launch command starts a new process. Never kill by process name; there may be a user instance. Kill the `$APP_PID` you started.
- The GUI recipe is unproven in this checkout because the host app lacks Accessibility permission. The CLI import feature is the proven path for store behavior.

## Next step if GUI automation is blocked

Grant Accessibility to the host app in System Settings → Privacy & Security → Accessibility, rerun `scripts/doctor.sh`, and only then run the click recipe. If the permission cannot be granted, verify the store invariants with an imported personal-audio fixture (`import-personal-audio`) and report the GUI gap honestly.
