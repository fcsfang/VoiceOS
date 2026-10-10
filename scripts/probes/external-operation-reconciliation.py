"""Separate SQLite stores emulate ambiguous side effects, NOT EventKit behavior."""
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile


def worker(local_path, external_path):
    import os
    local = sqlite3.connect(local_path)
    local.execute("INSERT INTO operations VALUES ('op-1', 'sending', NULL)")
    local.commit()
    external = sqlite3.connect(external_path)
    # The external store deliberately has no operation-key uniqueness constraint.
    external.execute("INSERT INTO items(marker, title) VALUES ('op-1', 'Synthetic task')")
    external.commit()
    os._exit(73)  # External commit succeeded; local receipt never persisted.


def reconcile(local, external, visible=True, permitted=True):
    if not permitted:
        return "blocked-permission"
    if not visible:
        return "unknown"  # No visible match is not evidence of a failed creation.
    matches = external.execute("SELECT id,title FROM items WHERE marker='op-1'").fetchall()
    if len(matches) != 1:
        return "unknown" if not matches else "ambiguous"
    identifier, title = matches[0]
    if title != "Synthetic task":
        return "conflict"  # Never replace a subsequent external edit with an old snapshot.
    local.execute("UPDATE operations SET state='confirmed', external_id=? WHERE identity='op-1'", (identifier,))
    local.commit()
    return "confirmed"


def main():
    cases = {}
    for case in ("receipt-lost", "visibility-delayed", "external-edited", "duplicate-marker", "permission-revoked", "external-deleted"):
        with tempfile.TemporaryDirectory(prefix="voiceos-external-probe-") as scratch:
            local_path, external_path = (Path(scratch) / name for name in ("local.sqlite3", "external.sqlite3"))
            local, external = sqlite3.connect(local_path), sqlite3.connect(external_path)
            local.execute("CREATE TABLE operations(identity TEXT PRIMARY KEY, state TEXT, external_id INTEGER)")
            external.execute("CREATE TABLE items(id INTEGER PRIMARY KEY, marker TEXT, title TEXT)")
            local.commit()
            external.commit()
            run = subprocess.run([sys.executable, __file__, "worker", str(local_path), str(external_path)],
                                 capture_output=True, text=True, timeout=10)
            if run.returncode != 73:
                raise RuntimeError(run.stderr or str(run.returncode))
            if case == "external-edited":
                external.execute("UPDATE items SET title='Edited elsewhere'")
            elif case == "duplicate-marker":
                external.execute("INSERT INTO items(marker,title) VALUES ('op-1','Synthetic task')")
            elif case == "external-deleted":
                external.execute("DELETE FROM items")
            external.commit()
            before = external.execute("SELECT * FROM items ORDER BY id").fetchall()
            status = reconcile(local, external, visible=case != "visibility-delayed", permitted=case != "permission-revoked")
            repeated = reconcile(local, external, visible=case != "visibility-delayed", permitted=case != "permission-revoked")
            expected = {"receipt-lost": "confirmed", "visibility-delayed": "unknown", "external-edited": "conflict",
                        "duplicate-marker": "ambiguous", "permission-revoked": "blocked-permission", "external-deleted": "unknown"}[case]
            checks = {"expected_state": status == expected, "restart_stable": repeated == status,
                      "no_external_replay_or_overwrite": before == external.execute("SELECT * FROM items ORDER BY id").fetchall()}
            if case == "visibility-delayed":
                checks["confirmed_after_visibility_returns"] = reconcile(local, external) == "confirmed"
            if case == "receipt-lost":
                checks["receipt_recovered"] = local.execute("SELECT state,external_id FROM operations").fetchone() == ("confirmed", before[0][0])
            cases[case] = {"state": status, "checks": checks}
            local.close()
            external.close()
    print(json.dumps({"probe": "external-reconciliation-simulation-v1", "cases": cases,
                      "scope": "fake external SQLite store; no Apple Reminders access, notifications, iCloud timing or concurrency validation"}, indent=2))
    if not all(all(item["checks"].values()) for item in cases.values()):
        raise SystemExit(1)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "worker":
        worker(sys.argv[2], sys.argv[3])
    else:
        main()
