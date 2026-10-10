"""Synthetic file/SQLite crash-window experiment; no recorder or product engine."""
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def worker(root, window):
    root = Path(root)
    db = sqlite3.connect(root / "state.sqlite3")
    db.execute("PRAGMA synchronous=FULL")
    db.execute("INSERT INTO sources VALUES ('source-1', 'writing', NULL)")
    db.commit()
    if window == "intent":
        os._exit(73)
    partial = root / "source-1.partial"
    with partial.open("xb") as output:
        output.write(b"synthetic-audio-chunk\n")
        output.flush()
        os.fsync(output.fileno())
    if window == "chunk":
        os._exit(73)
    expected = digest(partial)
    db.execute("UPDATE sources SET state='sealed', digest=?", (expected,))
    db.commit()
    if window == "sealed":
        os._exit(73)
    os.replace(partial, root / "source-1.raw")
    if window == "renamed":
        os._exit(73)
    db.execute("UPDATE sources SET state='ready'")
    db.commit()
    os._exit(73)


def recover(root):
    db = sqlite3.connect(root / "state.sqlite3")
    state, expected = db.execute("SELECT state, digest FROM sources").fetchone()
    partial, final = root / "source-1.partial", root / "source-1.raw"
    if state in ("interrupted-empty", "interrupted-with-fragment", "quarantined"):
        status = state
    elif state == "writing":
        # An interrupted chunk is retained for inspection, never declared complete.
        status = "interrupted-with-fragment" if partial.exists() else "interrupted-empty"
    elif expected is None:
        status = "quarantined"
    else:
        candidate = final if final.exists() else partial
        if not candidate.exists() or digest(candidate) != expected:
            status = "quarantined"
        else:
            if candidate == partial:
                os.replace(partial, final)
            status = "ready"
    db.execute("UPDATE sources SET state=?", (status,))
    db.commit()
    db.close()
    return status


def main():
    results = {}
    expectations = {"intent": "interrupted-empty", "chunk": "interrupted-with-fragment",
                    "sealed": "ready", "renamed": "ready", "ready": "ready",
                    "corrupt": "quarantined", "missing": "quarantined"}
    for window, expected in expectations.items():
        with tempfile.TemporaryDirectory(prefix="voiceos-resource-probe-") as scratch:
            root = Path(scratch)
            db = sqlite3.connect(root / "state.sqlite3")
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("CREATE TABLE sources (identity TEXT PRIMARY KEY, state TEXT, digest TEXT)")
            db.commit()
            db.close()
            actual_window = "ready" if window in ("corrupt", "missing") else window
            run = subprocess.run([sys.executable, __file__, "worker", str(root), actual_window],
                                 capture_output=True, text=True, timeout=10)
            if run.returncode != 73:
                raise RuntimeError(run.stderr or str(run.returncode))
            if window == "corrupt":
                (root / "source-1.raw").write_bytes(b"damaged")
            elif window == "missing":
                (root / "source-1.raw").unlink()
            recovered = recover(root)
            twice = recover(root)
            # Interrupted states remain interrupted on subsequent startup.
            checks = {"expected_state": recovered == expected, "restart_stable": twice == recovered}
            if window == "chunk":
                checks["fragment_retained"] = (root / "source-1.partial").exists()
            if expected == "ready":
                checks["exact_bytes"] = (root / "source-1.raw").read_bytes() == b"synthetic-audio-chunk\n"
            results[window] = {"state": recovered, "checks": checks}
    print(json.dumps({"probe": "cross-resource-recovery-v1", "windows": results,
                      "scope": "synthetic bytes and abrupt process exits; not media-container repair, microphone capture, power loss or Mac sleep"}, indent=2))
    if not all(all(item["checks"].values()) for item in results.values()):
        raise SystemExit(1)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "worker":
        worker(sys.argv[2], sys.argv[3])
    else:
        main()
