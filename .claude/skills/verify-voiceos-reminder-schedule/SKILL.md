---
name: verify-voiceos-reminder-schedule
description: Model-check VoiceOS reminder due-date writes for at-most-one external write and sound success recording. Use when a change touches executeReminderSchedule, reconcileReminderSchedule, observePendingScheduleOperations, reminder_schedule_operations, or recovery of reserved/unknown schedule operations.
---

# Verify VoiceOS reminder schedule

## What is verified

The reminder schedule protocol in `Sources/VoiceOSCore/ReminderScheduleOperation.swift`: a local schedule intent may change one Apple Reminders due date, but a crash, a re-delivered command, a lost save acknowledgment, or a read-only recovery must never cause a second external write or a success claim that the readback does not support.

Plain-language properties checked:

1. **One write per intent.** A schedule intent performs at most one external due-date write, ever, across crash, re-delivery, cancellation, and read-only reconciliation.
2. **Confirmed is sound.** `confirmed` implies the connector acknowledged the save, a readback matched exactly the desired due date, and only one write happened.
3. **Observed is honest.** `observed` implies a matching readback but no save acknowledgment, so the write cannot be attributed to VoiceOS.
4. **No retry after attempt.** Once `attempted=1`, the operation never returns to `reserved`; a crash before dispatch becomes `blocked`, not a retry.
5. **Conflict and blocked are read-only.** A preflight conflict, or a pre-dispatch crash, performs zero external writes.

## Tool and why

TLA+ 1.7.4, checked by TLC 2.19 under Java. The risk is event order and crash interleaving, not input values. TLA+ is the default tool for that shape in any language: it enumerates every reachable combination of reserve, dispatch, save-ack, readback, crash, manual edit, and read-only reconcile.

One command, pinned tool version, tiny state space (under 100 states generated, under 1 s):

```bash
.claude/skills/verify-voiceos-reminder-schedule/run.sh
```

The first run downloads `tla2tools.jar` v1.7.4 and refuses it unless the SHA-256 matches `936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88`. The jar is cached in `tools/` and gitignored.

Read every TLC result with the pstack `/pstack:statechart` skill. It renders each invariant violation as its shortest path in plain words and, when the check passes, charts how the system moves between states. Do not copy its commands here; invoke it by name.

## Coverage record

| Code | Regions the model describes | Sync commit |
|---|---|---|
| `Sources/VoiceOSCore/ReminderScheduleOperation.swift` | `executeReminderSchedule` (reserve, fresh preflight, dispatch-before-await, save-ack, after-write readback), `reconcileReminderSchedule`, `observePendingScheduleOperations`, `recordScheduleRead`, `authorizeScheduleOperation` | `141ac3f5090286686a2fc9a6721613d4ec35cd3d` |
| `Sources/VoiceOSCore/Store.swift` | `recover()`: `reserved` schedule operations become `blocked`; `unknown` stays for read-only reconciliation | `141ac3f5090286686a2fc9a6721613d4ec35cd3d` |
| `Sources/VoiceOSCore/Database.swift` | `reminder_schedule_operations` state, attempted, save_acknowledged, validity, result_observation_id | `141ac3f5090286686a2fc9a6721613d4ec35cd3d` |

Move a sync commit forward only after confirming the model still describes the code at the new commit.

## Bounds and assumptions

- One schedule intent, one reminder link, one external item, one operation per intent. Multiple intents or links racing are out of scope.
- The connector contract is taken as stated in `RemindersSchedulingPort`: `updateDue` may throw after the save succeeded, and the only truth is a fresh readback.
- External outcome is abstract: the write applies the desired due, is lost, or races a person who edits the due date. Identity, title, completion, and marker changes are modeled as a readback conflict.
- Not modeled: access-version or grant revocation timing, EventKit serialization, calendar time zones and date-only lossless-write rules, `ReminderScheduleMerge.decide` policy, UI presentation.
- The pass covers the protocol, not EventKit itself.

## Reading a result

`Model checking completed. No error has been found.` means every reachable schedule in the model satisfies the invariants. Anything else is a counterexample trace. Map the model states to code:

- `reserved` — operation row inserted, before `port.updateDue`; `attempted=0`.
- `unknown` — `state='unknown'`, `attempted=1` committed before the connector call; effect not yet confirmed.
- `confirmed` — save acknowledged and readback matched the desired due.
- `observed` — readback matched, save acknowledgment missing.
- `conflict` — identity or field change; keep the external value, do not overwrite.
- `blocked` — pre-dispatch crash or preflight failure; no write.

If the trace is a real bug, report it in code terms and do not weaken the property. If the trace is a modeling error, fix the model and rerun; do not change product code unless the user asks.

## Prove the check can fail

```bash
.claude/skills/verify-voiceos-reminder-schedule/run.sh --broken
```

Four variants replace `BrokenNext == FALSE` with one guard removal each:

| Variant | Removed guard | Invariant that must fail |
|---|---|---|
| `resend` | no second dispatch from `unknown` | `AtMostOneWrite` |
| `confirm` | `confirmed` requires save acknowledgment | `ConfirmedSound` |
| `observed` | `observed` requires missing save acknowledgment | `ObservedSound` |
| `preflight` | a preflight conflict writes but leaves `attempted=0` | `PreflightConflictNoWrite` |

The script exits nonzero unless every variant violates its intended invariant. A check that has never failed proves nothing.

## Findings

The shipped code at the sync commit passes all invariants. No bug was found. The model's conflict state covers identity, title, completion, and due-date changes; `recordScheduleRead` guards those fields before it records success.

A close second target: recording seal crash consistency in `RecordingCapture.sealDictation` and `Store.importMedia`/`recover()` — “a source reported `saved` always has a final asset whose SHA-256 matches, and a recoverable fragment is never discarded.” Ask before starting it.

## Keeping it in step

Rerun after any change to the covered functions or the `reminder_schedule_operations` schema. If the behavior change is intended, update the model and the property in the same change, rerun both modes, then move the sync commit. For a verification that has drifted from the code, use the pstack `/pstack:maintain-formal-verification-skill` skill. Do not delete a failing invariant to make the check green.
