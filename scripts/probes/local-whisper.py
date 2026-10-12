#!/usr/bin/env python3
"""Offline candidate evaluation. Download the pinned model separately first.

No cloud request, vocabulary prompt, transcript rewriting, or product DB writes.
Private transcript and timings go to an explicitly selected JSON file.
"""
import argparse
import importlib.metadata
import json
import os
from pathlib import Path
import resource
import time

os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("audio", type=Path)
    parser.add_argument("model", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--language", choices=["zh", "en"], default="zh")
    args = parser.parse_args()
    if not args.audio.is_file() or not (args.model / "weights.npz").is_file():
        parser.error("Local audio and downloaded model weights are required")
    if args.output.exists():
        parser.error("Refusing to overwrite a previous result")
    import mlx_whisper
    started = time.monotonic()
    result = mlx_whisper.transcribe(
        str(args.audio.resolve()), path_or_hf_repo=str(args.model.resolve()),
        language=args.language, task="transcribe", verbose=False,
        temperature=0.0, condition_on_previous_text=False,
        word_timestamps=False,
    )
    report = {
        "backend": "mlx-whisper", "package_version": importlib.metadata.version("mlx-whisper"),
        "elapsed_seconds": time.monotonic() - started, "language": result["language"],
        "peak_process_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
        "text": result["text"], "segments": result["segments"],
        "audio_uploaded": False, "initial_prompt": None,
        "condition_on_previous_text": False,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x", encoding="utf-8") as handle:
        json.dump(report, handle, ensure_ascii=False, indent=2)
    print(json.dumps({"elapsed_seconds": report["elapsed_seconds"],
                      "text_scalars": len(report["text"]), "audio_uploaded": False}))


if __name__ == "__main__":
    main()
