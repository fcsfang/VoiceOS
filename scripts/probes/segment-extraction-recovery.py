"""Real SIGKILL boundaries for durable, staged segment extraction."""
from __future__ import annotations
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile


def run(binary, command, root, crash=None):
    env = os.environ.copy()
    env.pop("VOICEOS_TEST_CRASH_AT", None)
    if crash:
        env["VOICEOS_TEST_CRASH_AT"] = crash
    return subprocess.run([binary, command, str(root)], capture_output=True, text=True, env=env, timeout=30)


def main():
    binary = os.environ.get("VOICEOS_CHECK_BINARY", ".build/debug/voiceos-check")
    cases = {"segmentExtractionReserved": "unknown", "segmentExtractionUncommitted": "unknown", "segmentExtractionCommitted": "completed"}
    results = {}
    with tempfile.TemporaryDirectory(prefix="voiceos-segment-extraction-") as scratch:
        for checkpoint, expected in cases.items():
            root = Path(scratch) / checkpoint
            crashed = run(binary, "segment-extraction-fixture", root, checkpoint)
            assert crashed.returncode == -signal.SIGKILL, (checkpoint, crashed.stderr)
            recovered = run(binary, "segment-extraction-read", root)
            assert recovered.returncode == 0, recovered.stderr
            data = json.loads(recovered.stdout)
            assert data["integrity"] and data["action_count"] == data["claim_count"] == data["old_model_count"] == 0
            batch = data["batches"][0]
            assert len(batch["attempts"]) == 1 and batch["attempts"][0]["state"] == expected, data
            assert batch["state"] == ("unknown" if expected == "unknown" else "queued")
            stable = run(binary, "segment-extraction-read", root)
            assert stable.returncode == 0 and json.loads(stable.stdout) == data
            resumed = run(binary, "segment-extraction-fixture", root)
            assert resumed.returncode == 0, resumed.stderr
            after = json.loads(resumed.stdout)
            resumed_batch = after["batches"][0]
            assert resumed_batch["attempts"][0]["id"] == batch["attempts"][0]["id"]
            if expected == "unknown":
                assert len(resumed_batch["attempts"]) == 1 and not resumed_batch["evidence_ready"]
            else:
                assert len(resumed_batch["attempts"]) == resumed_batch["segment_count"] and resumed_batch["evidence_ready"]
                sequences = [a["sequence"] for a in resumed_batch["attempts"]]
                assert sequences == sorted(set(sequences))
            replay = run(binary, "segment-extraction-fixture", root)
            assert replay.returncode == 0 and json.loads(replay.stdout) == after
            assert after["action_count"] == after["claim_count"] == after["old_model_count"] == 0
            results[checkpoint] = {"recovered_attempt": expected,"resumed_attempt_count": len(resumed_batch["attempts"]),"stable_replay": True,"no_product_entities": True}
    print(json.dumps({"probe": "segment-extraction-recovery-v1","cases": results,
                      "scope": "local synthetic port; no cloud calls, uploads, or reminder writes"}, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
