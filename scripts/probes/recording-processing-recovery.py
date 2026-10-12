"""Actual SIGKILL boundaries for explicit recording processing; synthetic media only."""
from __future__ import annotations
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile


def run(command: str, root: Path, checkpoint: str | None = None) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env.pop("VOICEOS_TEST_CRASH_AT", None)
    if checkpoint:
        env["VOICEOS_TEST_CRASH_AT"] = checkpoint
    return subprocess.run([os.environ.get("VOICEOS_CHECK_BINARY", ".build/debug/voiceos-check"), command, str(root)], env=env, capture_output=True, text=True, timeout=30)


def read(command: str, root: Path) -> dict:
    result = run(command, root)
    if result.returncode:
        raise RuntimeError(f"{command} failed: {result.stderr}")
    return json.loads(result.stdout)


def main() -> None:
    # expected resumed queues, cognition calls, association calls, queue outcome
    cases = {
        "recordingRequestUncommitted": (0, 0, 0, []),
        "recordingRequestCommitted": (0, 0, 0, []),
        "transcriptCommitted": (1, 1, 1, ["completed"]),
        "recordingRequestQueueCommitted": (1, 1, 1, ["completed"]),
        "modelReserved": (1, 1, 0, ["unknown"]),
        "claimsCommitted": (1, 1, 1, ["completed"]),
        "associationCommitted": (1, 1, 1, ["completed"]),
    }
    evidence = {}
    with tempfile.TemporaryDirectory(prefix="voiceos-record-request-recovery-") as scratch:
        for checkpoint, expected in cases.items():
            root = Path(scratch) / checkpoint
            crashed = run("record-request-fixture", root, checkpoint)
            if crashed.returncode != -signal.SIGKILL:
                raise RuntimeError(f"{checkpoint}: expected SIGKILL, got {crashed.returncode}: {crashed.stderr}")
            recovered = read("record-request-read", root)
            second = read("record-request-read", root)
            assert recovered == second, (checkpoint, "unstable repeated recovery")
            resumed = read("record-request-resume-fixture", root)
            replayed = read("record-request-resume-fixture", root)
            assert resumed == replayed, (checkpoint, "replay changed calls or identities")
            actual = (resumed["queue_count"], resumed["model_count"], resumed["association_count"], resumed["queue_states"])
            assert actual == expected, (checkpoint, expected, actual)
            assert recovered["integrity"] and resumed["integrity"]
            if checkpoint == "recordingRequestUncommitted":
                assert not recovered["requests"]
            elif checkpoint == "recordingRequestCommitted":
                assert resumed["requests"][0]["state"] == "waiting"
            else:
                assert resumed["requests"][0]["state"] == "enqueued"
            evidence[checkpoint] = {"crash_returncode":crashed.returncode,"recovered":recovered,"resumed":resumed,"stable_replay":True}
    output = {"probe":"recording-processing-recovery-v1","synthetic_tone_and_transcript":True,"microphone_used":False,"cloud_requests":0,"cases":evidence}
    path = Path("docs/research/evidence/recording-processing-recovery-2026-10-12.json")
    path.write_text(json.dumps(output, indent=2)+"\n")
    print(json.dumps({"passed":len(evidence),"evidence":str(path)}))


if __name__ == "__main__":
    main()
