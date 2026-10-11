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
        "processingIntentReserved": "running queue becomes unknown before any model reservation",
        "modelReserved": "reserved cognition becomes unknown and queue does not replay",
        "associationReserved": "reserved association becomes unknown after cognition commit",
    }
    results = {}
    with tempfile.TemporaryDirectory(prefix="voiceos-processing-recovery-") as scratch:
        base = Path(scratch)
        for checkpoint, description in cases.items():
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
            if len(intents) != 1 or intents[0]["state"] != "unknown":
                raise RuntimeError(f"{checkpoint}: unexpected recovery payload {payload}")
            second = run(binary, "expression-queue-read", root)
            if json.loads(second.stdout) != payload:
                raise RuntimeError(f"{checkpoint}: second recovery changed durable state")
            results[checkpoint] = {"description": description, "state": intents[0]["state"], "phase": intents[0]["phase"]}
    print(json.dumps({"probe": "expression-processing-recovery-v1", "cases": results, "scope": "local synthetic ports and actual SIGKILL checkpoints; no cloud calls or reminders"}, ensure_ascii=False, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
