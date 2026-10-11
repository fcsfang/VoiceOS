"""Exercise durable processing-intent recovery at actual model-stage checkpoints."""
from __future__ import annotations

import json
import os
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
        "processingIntentReserved": ("running queue becomes unknown before any model reservation", "unknown"),
        "modelReserved": ("reserved cognition becomes unknown and queue does not replay", "unknown"),
        "associationReserved": ("reserved association becomes unknown after cognition commit", "unknown"),
    }
    results = {}
    with tempfile.TemporaryDirectory(prefix="voiceos-processing-recovery-") as scratch:
        base = Path(scratch)
        for checkpoint, (description, expected) in cases.items():
            root = base / checkpoint
            root.mkdir()
            crashed = run(binary, "expression-queue-fixture", root, checkpoint)
            if crashed.returncode == 0:
                raise RuntimeError(f"{checkpoint}: fixture did not terminate at checkpoint: {crashed.stdout} {crashed.stderr}")
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
            if json.loads(second.stdout) != payload:
                raise RuntimeError(f"{checkpoint}: second recovery changed durable state")
            results[checkpoint] = {"description": description, "state": intents[0]["state"] if intents else "absent", "phase": intents[0]["phase"] if intents else "absent"}
    print(json.dumps({"probe": "expression-processing-recovery-v1", "cases": results, "scope": "local synthetic ports and actual SIGKILL checkpoints; no cloud calls or reminders"}, ensure_ascii=False, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
