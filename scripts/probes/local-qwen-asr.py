#!/usr/bin/env python3
"""Offline Qwen3-ASR evaluation; explicit local model, private new result file."""
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
    args = parser.parse_args()
    if not args.audio.is_file() or not (args.model / "model.safetensors").is_file():
        parser.error("Local audio and downloaded model weights are required")
    if args.output.exists():
        parser.error("Refusing to overwrite a previous result")
    from mlx_audio.stt import load
    started = time.monotonic()
    model = load(str(args.model.resolve()))
    result = model.generate(str(args.audio.resolve()), language="Chinese",
                            temperature=0.0, max_tokens=2048, verbose=False)
    report = {
        "backend": "mlx-audio/Qwen3-ASR-1.7B-8bit",
        "package_version": importlib.metadata.version("mlx-audio"),
        "elapsed_seconds": time.monotonic() - started,
        "peak_process_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
        "text": result.text, "segments": result.segments,
        "generation_tokens": result.generation_tokens,
        "token_budget_exhausted": result.generation_tokens >= 2048,
        "audio_uploaded": False, "initial_prompt": None,
        "timestamp_precision": "audio chunk boundaries, not word alignment",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x", encoding="utf-8") as handle:
        json.dump(report, handle, ensure_ascii=False, indent=2)
    print(json.dumps({"elapsed_seconds": report["elapsed_seconds"],
                      "text_scalars": len(report["text"]), "audio_uploaded": False}))


if __name__ == "__main__":
    main()
