#!/usr/bin/env python3
"""Versioned offline SpeechPort runner: Qwen 1.7B 8bit, pause-aware chunks up to 30s.

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
import time
import uuid

os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
IDENTITY = "Qwen3-ASR-1.7B-8bit@a8379a2 MLXAudio0.5.8 chunk30-pause-v2"



def audio_boundaries(samples, chunk_size, np):
    """Prefer an audible pause near the limit without dropping or overlapping samples.

    Only the final two seconds (at most 20% of the window) are considered.
    Fixed boundaries remain the fallback for speech without a measured pause.
    This is boundary placement, not a VAD or permission to omit quiet speech.
    """
    cuts, begin = [], 0
    frame = 160  # Measured 10 ms RMS windows at 16 kHz.
    while begin < len(samples):
        end = min(begin + chunk_size, len(samples))
        if end < len(samples):
            search = min(2 * 16000, chunk_size // 5)
            left = end - search
            segment = samples[left:end]
            count = len(segment) // frame
            energy = np.sqrt(np.mean(segment[:count * frame].reshape(count, frame) ** 2, axis=1))
            quiet = energy <= 0.003
            runs, start = [], None
            for index, value in enumerate(quiet):
                if value and start is None: start = index
                if start is not None and (not value or index == len(quiet) - 1):
                    stop = index if not value else index + 1
                    if stop - start >= 8: runs.append((start, stop))
                    start = None
            if runs:
                start, stop = max(runs, key=lambda pair: (pair[1] - pair[0], pair[1]))
                end = left + ((start + stop) // 2) * frame
        cuts.append((begin, end))
        begin = end
    return cuts


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--locale", choices=["zh_CN", "en_US"], default="zh_CN")
    parser.add_argument("--chunk-seconds", type=int, default=30)
    args = parser.parse_args()
    if not 1 <= args.chunk_seconds <= 30: parser.error("Chunk length must be between 1 and 30 seconds")
    if not args.audio.is_file() or not (args.model / "model.safetensors").is_file():
        parser.error("Local files are required")
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
    progress = args.output.with_suffix(".progress.json")
    identity = IDENTITY.replace("chunk30-pause-v2", f"chunk{args.chunk_seconds}-pause-v2")
    signature = {"audio": str(args.audio.resolve()), "bytes": args.audio.stat().st_size,
                 "model": str(args.model.resolve()), "locale": args.locale, "backend": identity,
                 "audio_sha256": hashlib.sha256(raw).hexdigest()}
    if args.output.exists():
        saved = json.loads(args.output.read_text())
        if saved.get("input_signature") != signature:
            raise ValueError("Saved transcription belongs to another input")
        print("Qwen 已完成，复用完整转写", flush=True)
        return
    state = json.loads(progress.read_text()) if progress.exists() else {}
    if state and state.get("input") != signature:
        raise ValueError("Saved transcription belongs to another input")
    model = None
    text, spans = state.get("text", ""), state.get("spans", [])
    chunk_size = args.chunk_seconds * 16000
    boundaries = audio_boundaries(samples, chunk_size, np)
    total = len(boundaries)
    started = time.monotonic()
    if state:
        print(f"Qwen 从已保存的 {state['next_sample'] / 16000:.1f}s 继续，保留 {len(spans)} 段", flush=True)

    def recognize(begin, end):
        nonlocal model
        chunk = samples[begin:end]
        if np.count_nonzero(chunk) == 0:
            return []
        if model is None:
            model = load(str(args.model.resolve()))
        result = model.generate(mx.array(chunk), language="Chinese" if args.locale == "zh_CN" else "English",
                                temperature=0.0, max_tokens=1024, verbose=False)
        mx.clear_cache()
        if result.generation_tokens >= 1024:
            if end - begin <= 16000:
                raise ValueError(f"Qwen {begin / 16000:.1f}–{end / 16000:.1f}s 仍无法完整识别；此前进度已保留")
            middle = (begin + end) // 2
            print(f"Qwen {begin / 16000:.1f}–{end / 16000:.1f}s 输出异常，自动拆短重识别；此前进度保留", flush=True)
            return recognize(begin, middle) + recognize(middle, end)
        return [(begin, end, result.text)] if result.text else []

    for ordinal, (begin, end) in enumerate(boundaries, 1):
        if end <= state.get("next_sample", 0): continue
        if begin < state.get("next_sample", 0): raise ValueError("Saved boundary does not match decoded audio")
        for part_begin, part_end, part in recognize(begin, end):
            spans.append({"id": str(uuid.uuid4()).upper(), "textStart": len(text),
                          "textEnd": len(text) + len(part), "startMS": round(part_begin / 16),
                          "endMS": round(part_end / 16)})
            text += part
        mx.clear_cache()
        completed = end
        temporary = progress.with_suffix(".tmp")
        temporary.write_text(json.dumps({"input": signature, "next_sample": completed,
                                        "text": text, "spans": spans}, ensure_ascii=False))
        temporary.replace(progress)
        print(f"Qwen {ordinal}/{total} · {completed / 16000:.1f}s · {len(text)} characters · {time.monotonic() - started:.0f}s elapsed", flush=True)
    with args.output.open("x", encoding="utf-8") as handle:
        json.dump({"backend": identity, "text": text, "spans": spans,
                   "timestamp_precision": f"pause-aware audio chunks up to {args.chunk_seconds} seconds; not word alignment",
                   "audio_uploaded": False, "input_signature": signature, "duration_seconds": len(samples) / 16000,
                   "processed_chunks": total, "total_chunks": total}, handle, ensure_ascii=False)
    progress.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
