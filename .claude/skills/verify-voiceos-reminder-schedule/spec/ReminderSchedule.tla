---- MODULE ReminderSchedule ----
\* A small model of VoiceOS reminder due-date writes.
\*
\* Code under verification:
\*   Sources/VoiceOSCore/ReminderScheduleOperation.swift
\*     executeReminderSchedule, reconcileReminderSchedule,
\*     observePendingScheduleOperations, recordScheduleRead,
\*     authorizeScheduleOperation
\*   Sources/VoiceOSCore/Store.swift
\*     recover() turns a reserved schedule operation into blocked
\*
\* One schedule intent, one external reminder, one operation. The external
\* connector is abstract: updateDue either applies the desired due, loses the
\* write, or races a person who edits the item. The model asks whether the
\* durable operation can ever write twice, or claim success without a matching
\* readback.

EXTENDS Naturals, TLC

CONSTANTS BaseDue, DesiredDue, ManualDue

VARIABLES state, attempted, saveAck, extDue, dispatches

vars == <<state, attempted, saveAck, extDue, dispatches>>

States == {"none", "reserved", "unknown", "confirmed", "observed", "conflict", "blocked"}

TypeOK ==
  /\ state \in States
  /\ attempted \in BOOLEAN
  /\ saveAck \in BOOLEAN
  /\ extDue \in {BaseDue, DesiredDue, ManualDue}
  /\ dispatches \in Nat

Init ==
  /\ state = "none"
  /\ attempted = FALSE
  /\ saveAck = FALSE
  /\ extDue = BaseDue
  /\ dispatches = 0

\* executeReminderSchedule inserts a reserved row after matching the intent,
\* link, access grant, and fresh preflight snapshot.
Reserve ==
  /\ state = "none"
  /\ extDue = BaseDue
  /\ state' = "reserved"
  /\ UNCHANGED <<attempted, saveAck, extDue, dispatches>>

\* The fresh preflight finds a changed identity or field. No external write.
PreflightConflict ==
  /\ state = "reserved"
  /\ extDue # BaseDue
  /\ state' = "conflict"
  /\ UNCHANGED <<attempted, saveAck, extDue, dispatches>>

\* The code commits state='unknown' and attempted=1 immediately before
\* port.updateDue. The external outcome is nondeterministic: applied, lost, or
\* edited by a person.
Dispatch ==
  /\ state = "reserved"
  /\ attempted = FALSE
  /\ extDue = BaseDue
  /\ state' = "unknown"
  /\ attempted' = TRUE
  /\ saveAck' = saveAck
  /\ dispatches' = dispatches + 1
  /\ extDue' \in {DesiredDue, BaseDue, ManualDue}

\* save_acknowledged=1 only after updateDue returned.
SaveAck ==
  /\ state = "unknown"
  /\ attempted = TRUE
  /\ saveAck = FALSE
  /\ saveAck' = TRUE
  /\ UNCHANGED <<state, attempted, extDue, dispatches>>

\* A readback, whether the direct after-write find or an ordinary timer read.
ReadBack ==
  /\ state = "unknown"
  /\ attempted = TRUE
  /\ extDue = DesiredDue
  /\ state' = IF saveAck THEN "confirmed" ELSE "observed"
  /\ UNCHANGED <<attempted, saveAck, extDue, dispatches>>

ReadBackConflict ==
  /\ state = "unknown"
  /\ attempted = TRUE
  /\ extDue # DesiredDue
  /\ state' = "conflict"
  /\ UNCHANGED <<attempted, saveAck, extDue, dispatches>>

\* recover() changes a reserved row to blocked; unknown is kept for read-only
\* reconcile.
CrashBeforeDispatch ==
  /\ state = "reserved"
  /\ attempted = FALSE
  /\ state' = "blocked"
  /\ UNCHANGED <<attempted, saveAck, extDue, dispatches>>

ManualEdit ==
  /\ state \in {"reserved", "unknown", "conflict"}
  /\ extDue' \in {BaseDue, DesiredDue, ManualDue}
  /\ extDue' # extDue
  /\ UNCHANGED <<state, attempted, saveAck, dispatches>>

\* reconcileReminderSchedule and observePendingScheduleOperations are read-only.
\* A conflict reached after a real attempt can become confirmed/observed when a
\* fresh readback matches; a conflict before dispatch cannot, because attempted
\* is still false.
Reconcile ==
  /\ state \in {"unknown", "conflict"}
  /\ attempted = TRUE
  /\ extDue = DesiredDue
  /\ state' = IF saveAck THEN "confirmed" ELSE "observed"
  /\ UNCHANGED <<attempted, saveAck, extDue, dispatches>>

Stutter == UNCHANGED vars

\* A broken variant replaces this with one reachable write or success that
\* skips a guard. It is FALSE in the model of the shipped code.
BrokenNext == FALSE

Next ==
  \/ Reserve
  \/ PreflightConflict
  \/ Dispatch
  \/ SaveAck
  \/ ReadBack
  \/ ReadBackConflict
  \/ CrashBeforeDispatch
  \/ ManualEdit
  \/ Reconcile
  \/ Stutter
  \/ BrokenNext

Spec == Init /\ [][Next]_vars

AtMostOneWrite == dispatches <= 1

UnknownOnlyAfterWrite == state = "unknown" => attempted /\ dispatches = 1

ConfirmedSound ==
  state = "confirmed" => attempted /\ saveAck /\ extDue = DesiredDue /\ dispatches = 1

ObservedSound ==
  state = "observed" => attempted /\ ~saveAck /\ extDue = DesiredDue /\ dispatches = 1

NoReservedAfterAttempt == attempted => state # "reserved"

NoDispatchWithoutAttempt == dispatches = 0 \/ attempted

PreflightConflictNoWrite == state = "conflict" /\ ~attempted => dispatches = 0

BlockedNoWrite == state = "blocked" => dispatches = 0

====
