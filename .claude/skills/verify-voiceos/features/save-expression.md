# Save an expression

## Sub-features

- `保存表达` writes the original text locally without any model call.
- `保存并处理本次文字` requires a configured text model and queues the durable processing intent.
- The 4000-scalar cap and the non-empty check gate both buttons.
- A command ID is generated per dialog; re-delivery with the same ID must not create a second source.

## How to get to it (user POV)

In the app: click `记录我的表达`, type into the text editor, then `保存表达`. The source appears as a user expression; the app status says the original is saved locally and has not been sent.

## Driving it with SwiftUI + `voiceos-check`

GUI drive needs Accessibility permission. With it:

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

Then inspect the store:

```bash
"$ROOT/.build/debug/voiceos-check" read "$DATA"
sqlite3 "$DATA/voiceos.sqlite" "SELECT state,kind,origin,speaker,local_only,expected_bytes FROM sources;"
```

Observable end state: one source with `state=saved`, `kind=user_text`, `origin=user`, `speaker=user`, and a positive `expected_bytes`. There is no `model_attempts` row and no processing intent from the plain save path.

## Gotchas

- `保存并处理本次文字` is disabled until a text model is configured; do not treat a disabled button as a broken save.
- The plain save is local-only by policy. Do not enable cloud processing to make a test pass.
- SwiftUI sheet indexing can differ across macOS versions. If `sheet 1` is not the dialog, inspect `entire contents` once and adjust the selector.
- The command ID lives in the dialog state; closing and reopening creates a new ID, so re-delivery is tested at the store API level, not by clicking twice.

## Proven in this checkout

The GUI recipe is unproven here because the host app lacks Accessibility permission. The store-level invariant is visible in `Sources/VoiceOSCore/Store.swift` (`commitUserText`) and in `VoiceOSApp.swift` (`saveExpression`); the click path remains an explicit verification gap.
