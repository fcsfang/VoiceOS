"""Exercise durable processing-intent recovery at actual model-stage checkpoints."""
from __future__ import annotations

import json
import os
import signal
from pathlib import Path
import subprocess
import tempfile


def run(binary: str, command: str, root: Path, crash: str | None = None) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    if crash is None:
        env.pop("VOICEOS_TEST_CRASH_AT", None)
    else:
        env["VOICEOS_TEST_CRASH_AT"] = crash
    return subprocess.run([binary, command, str(root)], env=env, text=True, capture_output=True, timeout=30)


def main() -> None:
    binary = os.environ.get("VOICEOS_CHECK_BINARY", ".build/debug/voiceos-check")
    cases = {
        "processingIntentUncommitted": ("uncommitted queue insert rolls back without leaving an intent", "empty"),
        "processingIntentCommitted": ("committed queue insert remains queued after restart", "queued"),
        "processingIntentReserved": ("unreserved model stage is safely queued after restart", "queued"),
        "modelReserved": ("reserved cognition becomes unknown and queue does not replay", "unknown"),
        "claimsCommitted": ("completed cognition is linked and only unreserved association resumes", "queued"),
        "associationReserved": ("reserved association becomes unknown after cognition commit", "unknown"),
        "associationCommitted": ("completed association settles queue without replay", "completed"),
    }
    results = {}
    with tempfile.TemporaryDirectory(prefix="voiceos-processing-recovery-") as scratch:
        base = Path(scratch)
        for checkpoint, (description, expected) in cases.items():
            root = base / checkpoint
            root.mkdir()
            crashed = run(binary, "expression-queue-fixture", root, checkpoint)
            if crashed.returncode != -signal.SIGKILL:
                raise RuntimeError(f"{checkpoint}: fixture did not terminate by SIGKILL: {crashed.returncode} {crashed.stdout} {crashed.stderr}")
            recovered = run(binary, "expression-queue-read", root)
            if recovered.returncode != 0:
                raise RuntimeError(f"{checkpoint}: recovery failed: {recovered.stdout} {recovered.stderr}")
            payload = json.loads(recovered.stdout)
            intents = payload["intents"]
            if expected == "empty":
                if intents:
                    raise RuntimeError(f"{checkpoint}: rolled-back insert left durable intents {payload}")
            elif len(intents) != 1 or intents[0]["state"] != expected:
                raise RuntimeError(f"{checkpoint}: unexpected recovery payload {payload}")
            second = run(binary, "expression-queue-read", root)
            if second.returncode != 0 or json.loads(second.stdout) != payload:
                raise RuntimeError(f"{checkpoint}: second recovery changed durable state")
            resumed = run(binary, "expression-queue-fixture", root)
            expected_after = "unknown" if expected == "unknown" else "completed"
            if resumed.returncode != 0 or json.loads(resumed.stdout)["state"] != expected_after:
                raise RuntimeError(f"{checkpoint}: invalid resumed state: {resumed.stdout} {resumed.stderr}")
            after = json.loads(run(binary, "expression-queue-read", root).stdout)
            expected_counts = (1, 0) if checkpoint == "modelReserved" else (1, 1)
            if (after["cognition_attempt_count"], after["association_attempt_count"]) != expected_counts:
                raise RuntimeError(f"{checkpoint}: resumed attempt counts invalid {after}")
            replay = run(binary, "expression-queue-fixture", root)
            stable = run(binary, "expression-queue-read", root)
            if replay.returncode != 0 or stable.returncode != 0 or json.loads(stable.stdout) != after:
                raise RuntimeError(f"{checkpoint}: terminal replay changed history")
            results[checkpoint] = {"description": description, "state": intents[0]["state"] if intents else "absent", "phase": intents[0]["phase"] if intents else "absent", "resumed_state": expected_after, "cognition_attempts": after["cognition_attempt_count"], "association_attempts": after["association_attempt_count"]}
    print(json.dumps({"probe": "expression-processing-recovery-v2", "cases": results, "scope": "local synthetic ports, SIGKILL and resumed/replayed fixtures; no cloud calls or reminders"}, ensure_ascii=False, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
