#!/usr/bin/env python3
"""Versioned offline SpeechPort runner: Qwen 1.7B 8bit, independent 30s chunks.

Timestamp ranges identify actual audio chunks, not word alignment. Only exact
digital silence is skipped; this is not a general voice-activity detector.
"""
import argparse
import importlib.metadata
import hashlib
import json
import os
from pathlib import Path
import subprocess
import uuid

os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
IDENTITY = "Qwen3-ASR-1.7B-8bit@a8379a2 MLXAudio0.5.8 chunk30-v1"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--locale", choices=["zh_CN", "en_US"], default="zh_CN")
    args = parser.parse_args()
    if args.output.exists() or not args.audio.is_file() or not (args.model / "model.safetensors").is_file():
        parser.error("Local files and a new output are required")
    if importlib.metadata.version("mlx-audio") != "0.5.8":
        raise RuntimeError("Unexpected MLX Audio runtime version")
    digest = hashlib.sha256()
    with (args.model / "model.safetensors").open("rb") as weights:
        while block := weights.read(4 * 1024 * 1024):
            digest.update(block)
    if digest.hexdigest() != "bf304b009cc7eca79283056f787b44c952d24ac22cec787b39732bba3c23c13c":
        raise ValueError("Model identity mismatch")
    import mlx.core as mx
    import numpy as np
    from mlx_audio.stt import load
    raw = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", str(args.audio.resolve()),
                          "-vn", "-ac", "1", "-ar", "16000", "-f", "f32le", "-"],
                         check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=180).stdout
    samples = np.frombuffer(raw, dtype=np.float32)
    if not samples.size or not np.isfinite(samples).all():
        raise ValueError("Decoded audio is empty or invalid")
    model = None
    text, spans = "", []
    chunk_size = 30 * 16000
    for begin in range(0, len(samples), chunk_size):
        chunk = samples[begin:begin + chunk_size]
        if np.count_nonzero(chunk) == 0:
            continue
        if model is None:
            model = load(str(args.model.resolve()))
        result = model.generate(mx.array(chunk), language="Chinese" if args.locale == "zh_CN" else "English",
                                temperature=0.0, max_tokens=1024, verbose=False)
        if result.generation_tokens >= 1024:
            raise ValueError("Chunk token budget exhausted; refusing partial transcript")
        part = result.text
        if part:
            spans.append({"id": str(uuid.uuid4()).upper(), "textStart": len(text),
                          "textEnd": len(text) + len(part), "startMS": round(begin / 16),
                          "endMS": round((begin + len(chunk)) / 16)})
            text += part
        mx.clear_cache()
    with args.output.open("x", encoding="utf-8") as handle:
        json.dump({"backend": IDENTITY, "text": text, "spans": spans,
                   "timestamp_precision": "audio chunks up to 30 seconds; not word alignment",
                   "audio_uploaded": False}, handle, ensure_ascii=False)


if __name__ == "__main__":
    main()
