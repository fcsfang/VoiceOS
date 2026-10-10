"""Isolated SQLite crash/uniqueness probe with synthetic rows, not a job engine."""
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile


def main():
    with tempfile.TemporaryDirectory(prefix="voiceos-sqlite-probe-") as scratch:
        database = Path(scratch) / "probe.sqlite3"
        connection = sqlite3.connect(database)
        journal = connection.execute("PRAGMA journal_mode=WAL").fetchone()[0]
        connection.execute("PRAGMA synchronous=FULL")
        connection.execute("CREATE TABLE operations (identity TEXT PRIMARY KEY, state TEXT NOT NULL)")
        connection.commit()
        connection.close()

        def crash_writer(identity, commit):
            code = """
import os, sqlite3, sys
c=sqlite3.connect(sys.argv[1])
c.execute('PRAGMA synchronous=FULL')
c.execute('INSERT INTO operations VALUES (?, ?)', (sys.argv[2], 'queued'))
if sys.argv[3]=='commit': c.commit()
os._exit(73)
"""
            process = subprocess.run(
                [sys.executable, "-c", code, str(database), identity, "commit" if commit else "uncommitted"],
                capture_output=True, text=True, timeout=10,
            )
            if process.returncode != 73:
                raise RuntimeError(process.stderr or f"unexpected worker exit: {process.returncode}")

        crash_writer("committed-operation", True)
        crash_writer("uncommitted-operation", False)
        connection = sqlite3.connect(database)
        committed = connection.execute("SELECT state FROM operations WHERE identity=?", ("committed-operation",)).fetchone()
        uncommitted = connection.execute("SELECT state FROM operations WHERE identity=?", ("uncommitted-operation",)).fetchone()
        duplicate_rejected = False
        try:
            connection.execute("INSERT INTO operations VALUES (?, ?)", ("committed-operation", "queued"))
            connection.commit()
        except sqlite3.IntegrityError:
            duplicate_rejected = True
            connection.rollback()
        count = connection.execute("SELECT COUNT(*) FROM operations").fetchone()[0]
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        connection.close()
        checks = {
            "committed_row_survives_process_exit": committed == ("queued",),
            "uncommitted_row_rolled_back": uncommitted is None,
            "duplicate_identity_rejected": duplicate_rejected and count == 1,
            "database_integrity_ok": integrity == "ok",
        }
        print(json.dumps({
            "probe": "sqlite-crash-uniqueness-v1", "sqlite_version": sqlite3.sqlite_version,
            "journal_mode": journal, "synchronous": "FULL", "checks": checks,
            "scope": "synthetic database only; no power-loss, sleep, cross-resource atomicity, or external-write test",
        }, ensure_ascii=False, indent=2))
        if not all(checks.values()):
            raise SystemExit(1)


if __name__ == "__main__":
    main()
