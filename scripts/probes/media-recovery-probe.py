"""Private existing-media/SQLite SIGKILL experiment, not a product importer.

Only fresh scratch copies are modified. No recording, model or external calls.
The validator reads containers and decodes audio; it does not decode video frames.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import signal
import sqlite3
import subprocess
import sys


WINDOWS = (
    "intent", "copy_chunk", "copy_complete", "sealed", "renamed",
    "saved_uncommitted", "saved_committed", "recovery_renamed",
    "corrupt", "missing", "invalid_media", "input_unavailable",
)


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def connect(root):
    db = sqlite3.connect(root / "state.sqlite3")
    db.execute("PRAGMA synchronous=FULL")
    db.execute("PRAGMA foreign_keys=ON")
    return db


def initialize(root, suffix):
    db = connect(root)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("CREATE TABLE sources (id TEXT PRIMARY KEY, state TEXT NOT NULL, bytes INTEGER NOT NULL, digest TEXT NOT NULL, suffix TEXT NOT NULL, validation TEXT, reason TEXT)")
    db.execute("CREATE TABLE jobs (source_id TEXT PRIMARY KEY REFERENCES sources(id), stage TEXT NOT NULL, state TEXT NOT NULL)")
    db.commit()
    db.close()
    sync_directory(root)


def paths(root, suffix):
    return root / ("asset.partial" + suffix), root / ("asset" + suffix)


def checkpoint(stage, requested):
    if stage == requested:
        print(stage, flush=True)
        # Parent kills this exact child; EOF without kill is a test error.
        sys.stdin.readline()
        raise RuntimeError("checkpoint released without SIGKILL")


def validate(validator, path):
    result = subprocess.run([str(validator), str(path)], capture_output=True, text=True, timeout=20)
    if result.returncode not in (0, 1):
        raise RuntimeError("native validator failed unexpectedly")
    value = json.loads(result.stdout)
    return value if result.returncode == 0 and value.get("valid") else None


def mark_saved(db):
    # Source + queued stage identity must commit atomically.
    db.execute("UPDATE sources SET state='saved', reason=NULL")
    db.execute("INSERT OR IGNORE INTO jobs VALUES ('source-1', 'transcribe', 'queued')")


def worker(root, validator, requested):
    metadata = json.loads((root / "input.json").read_text())
    source = root / ("input" + metadata["suffix"])
    partial, final = paths(root, metadata["suffix"])
    db = connect(root)
    db.execute("INSERT INTO sources VALUES ('source-1', 'receiving', ?, ?, ?, NULL, NULL)",
               (metadata["bytes"], metadata["digest"], metadata["suffix"]))
    db.commit()
    checkpoint("intent", requested)
    with source.open("rb") as incoming, partial.open("xb") as output:
        first = True
        for chunk in iter(lambda: incoming.read(65536), b""):
            output.write(chunk)
            if first:
                output.flush()
                os.fsync(output.fileno())
                sync_directory(root)
                checkpoint("copy_chunk", requested)
                first = False
        output.flush()
        os.fsync(output.fileno())
    sync_directory(root)
    checkpoint("copy_complete", requested)
    if partial.stat().st_size != metadata["bytes"] or digest(partial) != metadata["digest"]:
        raise RuntimeError("copy identity mismatch")
    container = validate(validator, partial)
    if container is None:
        raise RuntimeError("input fixture not a valid supported media container")
    db.execute("UPDATE sources SET state='sealed', validation=?", (json.dumps(container),))
    db.commit()
    checkpoint("sealed", requested)
    os.replace(partial, final)
    sync_directory(root)
    checkpoint("renamed", requested)
    db.execute("BEGIN IMMEDIATE")
    mark_saved(db)
    checkpoint("saved_uncommitted", requested)
    db.commit()
    checkpoint("saved_committed", requested)
    raise RuntimeError("unknown checkpoint")


def recover(root, validator, pause=None):
    db = connect(root)
    state, size, expected, suffix = db.execute("SELECT state, bytes, digest, suffix FROM sources").fetchone()
    partial, final = paths(root, suffix)
    if state == "receiving":
        # Imports have known full length/hash recorded before copying. Recording
        # fragments without this contract cannot use this automatic completion.
        complete = partial.exists() and partial.stat().st_size == size and digest(partial) == expected
        container = validate(validator, partial) if complete else None
        if container is not None:
            state = "sealed"
            db.execute("UPDATE sources SET state=?, validation=?, reason=NULL", (state, json.dumps(container)))
        else:
            state = "interrupted-unsealed" if partial.exists() else "interrupted-empty"
            db.execute("UPDATE sources SET state=?, reason='copy_not_sealed'", (state,))
        db.commit()
    if state in ("interrupted-empty", "interrupted-unsealed", "quarantined"):
        pass
    else:
        candidate = final if final.exists() else partial
        reason = None
        container = None
        if not candidate.exists():
            reason = "missing"
        elif candidate.stat().st_size != size or digest(candidate) != expected:
            reason = "digest_or_length_mismatch"
        else:
            container = validate(validator, candidate)
            if container is None:
                reason = "invalid_media_container"
        if reason:
            state = "quarantined"
            db.execute("UPDATE sources SET state=?, reason=?", (state, reason))
            db.execute("UPDATE jobs SET state='blocked'")
            db.commit()
        else:
            if candidate == partial:
                os.replace(partial, final)
                sync_directory(root)
                checkpoint("recovery_renamed", pause)
            db.execute("BEGIN IMMEDIATE")
            db.execute("UPDATE sources SET validation=?", (json.dumps(container),))
            mark_saved(db)
            db.commit()
            state = "saved"
    integrity = db.execute("PRAGMA integrity_check").fetchone()[0]
    fk = db.execute("PRAGMA foreign_key_check").fetchall()
    job_count = db.execute("SELECT COUNT(*) FROM jobs").fetchone()[0]
    queued = db.execute("SELECT COUNT(*) FROM jobs WHERE state='queued'").fetchone()[0]
    reason = db.execute("SELECT reason FROM sources").fetchone()[0]
    db.close()
    return {"state": state, "reason": reason, "job_count": job_count, "queued_job_count": queued,
            "integrity_ok": integrity == "ok", "foreign_keys_ok": not fk}


def kill_at(root, validator, mode, stage):
    command = [sys.executable, str(Path(__file__).resolve()), mode, str(root), str(validator), stage]
    with (root / (mode + "-stderr.txt")).open("w") as errors:
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=errors, text=True)
        try:
            ready, _, _ = select.select([process.stdout], [], [], 30)
            if not ready or process.stdout.readline().strip() != stage:
                raise RuntimeError("child did not reach checkpoint: " + stage)
            process.send_signal(signal.SIGKILL)
            if process.wait(timeout=10) != -signal.SIGKILL:
                raise RuntimeError("unexpected child termination")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=10)
            process.stdin.close()
            process.stdout.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixtures", type=Path, required=True)
    parser.add_argument("--validator", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    validator = args.validator.resolve(strict=True)
    fixtures = json.loads(args.fixtures.read_text())
    chosen = [(item["sample_id"], Path(item["copied_path"] if item["sample_id"] == "V01" else item["clip_path"])) for item in fixtures]
    if set(sid for sid, _ in chosen) != {"A01", "V01"} or len(chosen) != 2:
        raise RuntimeError("expected the two previously authorized fixtures")
    snapshots = {sid: digest(path) for sid, path in chosen}
    args.output.mkdir(parents=True, exist_ok=False)
    results = []
    for sid, fixture in chosen:
        baseline = validate(validator, fixture)
        if baseline is None:
            raise RuntimeError("baseline fixture validation failed")
        for window in WINDOWS:
            root = args.output / sid / window
            root.mkdir(parents=True)
            suffix = fixture.suffix
            source = root / ("input" + suffix)
            shutil.copyfile(fixture, source)
            metadata = {"suffix": suffix, "bytes": source.stat().st_size, "digest": digest(source)}
            (root / "input.json").write_text(json.dumps(metadata))
            initialize(root, suffix)
            stage = window if window in WINDOWS[:7] else "sealed" if window in ("recovery_renamed", "invalid_media", "input_unavailable") else "saved_committed"
            kill_at(root, validator, "worker", stage)
            partial, final = paths(root, suffix)
            killed = 1
            if window == "recovery_renamed":
                kill_at(root, validator, "recover-worker", window)
                killed += 1
            elif window == "corrupt":
                final.write_bytes(b"fault-injection-damaged-scratch-copy")
            elif window == "missing":
                final.unlink()
            elif window == "invalid_media":
                partial.write_bytes(b"fault-injection-not-a-media-container")
                db = connect(root)
                # Simulate bad sealed metadata: hash equality alone must not pass.
                db.execute("UPDATE sources SET bytes=?, digest=?", (partial.stat().st_size, digest(partial)))
                db.commit()
                db.close()
            elif window == "input_unavailable":
                os.replace(source, root / ("unavailable-input" + suffix))
            # Observe the crash snapshot before recovery could repair it. This
            # directly checks transaction rollback/commit, not only final state.
            db = connect(root)
            before_state = db.execute("SELECT state FROM sources").fetchone()[0]
            before_jobs = db.execute("SELECT COUNT(*) FROM jobs").fetchone()[0]
            db.close()
            expected_before = "receiving" if window in ("intent", "copy_chunk", "copy_complete") else "saved" if window in ("saved_committed", "corrupt", "missing") else "sealed"
            first = recover(root, validator)
            second = recover(root, validator)
            expected = "interrupted-empty" if window == "intent" else "interrupted-unsealed" if window == "copy_chunk" else "quarantined" if window in ("corrupt", "missing", "invalid_media") else "saved"
            prior_job = window in ("corrupt", "missing")
            checks = {"expected_state": first["state"] == expected,
                      "restart_stable": first == second,
                      "database_integrity": first["integrity_ok"] and first["foreign_keys_ok"],
                      "atomic_snapshot_after_SIGKILL": before_state == expected_before and before_jobs == (1 if expected_before == "saved" else 0),
                      "one_source_identity": True,
                      "job_identity_count": first["job_count"] == (1 if expected == "saved" or prior_job else 0),
                      "queued_only_if_saved": first["queued_job_count"] == (1 if expected == "saved" else 0)}
            db = connect(root)
            checks["one_source_identity"] = db.execute("SELECT COUNT(*) FROM sources").fetchone()[0] == 1
            db.close()
            if expected == "saved":
                native = validate(validator, final)
                checks["exact_original_bytes"] = digest(final) == snapshots[sid]
                checks["native_decode_matches_baseline"] = native is not None and native["decoded_audio_frames"] == baseline["decoded_audio_frames"] and native["video_tracks"] == baseline["video_tracks"]
            if expected == "interrupted-unsealed":
                checks["unsealed_bytes_retained"] = partial.exists() and partial.stat().st_size > 0
            if window == "input_unavailable":
                checks["recovered_without_original_input_path"] = not source.exists() and final.exists()
            entry = {"sample_id": sid, "window": window, "SIGKILL_count": killed,
                     "before_recovery": {"state": before_state, "job_count": before_jobs},
                     "recovery": first, "checks": checks}
            results.append(entry)
            (root / "case-result.json").write_text(json.dumps(entry, indent=2))
            print(json.dumps({"sample": sid, "window": window, "state": first["state"], "checks_pass": all(checks.values())}), flush=True)
    unchanged = all(digest(path) == snapshots[sid] for sid, path in chosen)
    summary = {"probe": "existing-media-sigkill-recovery-v3", "case_count": len(results),
               "all_checks_pass": unchanged and all(all(item["checks"].values()) for item in results),
               "baseline_fixture_files_unchanged": unchanged, "samples": [sid for sid, _ in chosen],
               "windows": list(WINDOWS), "cases": results,
               "directory_fsync_completed": True, "sqlite_version": sqlite3.sqlite_version,
               "journal_mode": "WAL", "synchronous": "FULL",
               "scope": "private scratch MP4/M4A copies, actual child SIGKILL, probe SQLite and native audio decode; not product importer, microphone capture, Mac sleep, hardware power loss, video-frame decode or external operations"}
    (args.output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"case_count": len(results), "all_checks_pass": summary["all_checks_pass"], "baseline_fixture_files_unchanged": unchanged}), flush=True)
    if not summary["all_checks_pass"]:
        raise SystemExit(1)


if __name__ == "__main__":
    if len(sys.argv) == 5 and sys.argv[1] in ("worker", "recover-worker"):
        root, validator, stage = Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4]
        worker(root, validator, stage) if sys.argv[1] == "worker" else recover(root, validator, stage)
    else:
        main()
