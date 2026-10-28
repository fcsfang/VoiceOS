#!/usr/bin/env python3
import pathlib
import sys

BASE = pathlib.Path(__file__).resolve().parents[1] / "ReminderSchedule.tla"

ACTIONS = {
    "resend": """
BrokenNext ==
  /\\ state = "unknown"
  /\\ attempted = TRUE
  /\\ state' = "unknown"
  /\\ dispatches' = dispatches + 1
  /\\ UNCHANGED <<attempted, saveAck, extDue>>
""",
    "confirm": """
BrokenNext ==
  /\\ state = "unknown"
  /\\ attempted = TRUE
  /\\ extDue = DesiredDue
  /\\ state' = "confirmed"
  /\\ UNCHANGED <<attempted, saveAck, extDue, dispatches>>
""",
    "observed": """
BrokenNext ==
  /\\ state = "unknown"
  /\\ attempted = TRUE
  /\\ saveAck = TRUE
  /\\ extDue = DesiredDue
  /\\ state' = "observed"
  /\\ UNCHANGED <<attempted, saveAck, extDue, dispatches>>
""",
    "preflight": """
BrokenNext ==
  /\\ state = "reserved"
  /\\ extDue = ManualDue
  /\\ state' = "conflict"
  /\\ dispatches' = dispatches + 1
  /\\ UNCHANGED <<attempted, saveAck, extDue>>
""",
}


def main() -> None:
    if len(sys.argv) != 3 or sys.argv[1] not in ACTIONS:
        raise SystemExit(f"usage: make_broken.py {{{'|'.join(ACTIONS)}}} <output.tla>")
    mode, output = sys.argv[1], pathlib.Path(sys.argv[2])
    text = BASE.read_text()
    text = text.replace("---- MODULE ReminderSchedule ----", f"---- MODULE {output.stem} ----")
    text = text.replace("BrokenNext == FALSE", ACTIONS[mode].strip())
    output.write_text(text)


if __name__ == "__main__":
    main()
