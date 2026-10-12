"""Actual SIGKILL tests for local segmented-batch enqueue/cancel transactions."""
from __future__ import annotations
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile


def run(binary: str, command: str, root: Path, crash: str | None = None):
    env = os.environ.copy()
    env.pop("VOICEOS_TEST_CRASH_AT", None)
    if crash:
        env["VOICEOS_TEST_CRASH_AT"] = crash
    return subprocess.run([binary, command, str(root)], env=env, capture_output=True, text=True, timeout=30)


def main():
    binary = os.environ.get("VOICEOS_CHECK_BINARY", ".build/debug/voiceos-check")
    cases = {"segmentedBatchUncommitted": "absent", "segmentedBatchCommitted": "queued",
             "segmentedBatchCancelUncommitted": "queued", "segmentedBatchCancelCommitted": "cancelled"}
    results = {}
    with tempfile.TemporaryDirectory(prefix="voiceos-segmented-recovery-") as scratch:
        for checkpoint, expected in cases.items():
            root = Path(scratch) / checkpoint
            command = "segmented-batch-cancel-fixture" if "Cancel" in checkpoint else "segmented-batch-fixture"
            crashed = run(binary, command, root, checkpoint)
            assert crashed.returncode == -signal.SIGKILL, (checkpoint, crashed.stderr)
            recovered = run(binary, "segmented-batch-read", root)
            assert recovered.returncode == 0, recovered.stderr
            payload = json.loads(recovered.stdout)
            states = [b["state"] for b in payload["batches"]]
            assert states == ([] if expected == "absent" else [expected]), payload
            assert payload["integrity"] and payload["model_count"] == payload["queue_count"] == payload["action_count"] == 0, payload
            second = run(binary, "segmented-batch-read", root)
            assert second.returncode == 0 and json.loads(second.stdout) == payload
            replay = run(binary, "segmented-batch-fixture", root)
            assert replay.returncode == 0, replay.stderr
            after = json.loads(replay.stdout)
            assert [b["state"] for b in after["batches"]] == ["cancelled" if expected == "cancelled" else "queued"], after
            if expected != "absent":
                assert after["batches"][0]["id"] == payload["batches"][0]["id"]
            again = run(binary, "segmented-batch-fixture", root)
            assert again.returncode == 0 and json.loads(again.stdout) == after
            results[checkpoint] = {"recovered_state": expected, "stable_replay": True, "no_model_or_actions": True}
    print(json.dumps({"probe": "segmented-processing-recovery-v1", "cases": results,
                      "scope": "synthetic local text; no model dispatch, audio upload, or reminder writes"}, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
