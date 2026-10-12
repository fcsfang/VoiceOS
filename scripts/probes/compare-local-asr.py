#!/usr/bin/env python3
"""Make a sanitized structural/latency report, never an accuracy score."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("audio", type=Path)
    parser.add_argument("results", type=Path, nargs="+")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    duration = float(subprocess.check_output([
        "ffprobe", "-v", "error", "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1", str(args.audio)
    ], text=True).strip())
    rows = []
    for path in args.results:
        result = json.loads(path.read_text())
        text = result["text"]
        spans = result.get("spans", result.get("segments", []))
        ranges = []
        for span in spans:
            start, end = ((span.get("startMS"), span.get("endMS"))
                          if "textStart" in span else (span.get("start"), span.get("end")))
            scale = 1000 if "textStart" in span else 1
            if start is None or end is None:
                ranges.append(None)
            else:
                ranges.append((start / scale, end / scale))
        elapsed = result["elapsed_seconds"]
        rows.append({
            "backend": result["backend"], "elapsed_seconds": elapsed,
            "real_time_factor": elapsed / duration, "text_scalars": len(text),
            "text_sha256": hashlib.sha256(text.encode()).hexdigest(),
            "has_alphanumeric_text": any(c.isalnum() for c in text),
            "span_count": len(spans),
            "all_time_ranges_in_audio": all(
                r is not None and all(math.isfinite(t) for t in r)
                and 0 <= r[0] <= r[1] <= duration + .001 for r in ranges),
            "timestamp_precision": result.get("timestamp_precision", "recognizer segments"),
            "token_budget_exhausted": result.get("token_budget_exhausted", False),
            "peak_process_rss_bytes": result.get("peak_process_rss_bytes"),
            "audio_uploaded": result["audio_uploaded"],
        })
    report = {"audio_sha256": hashlib.sha256(args.audio.read_bytes()).hexdigest(),
              "audio_duration_seconds": duration, "results": rows,
              "human_reference_available": False, "accuracy_scored": False,
              "limitation": "Latency and valid time ranges do not establish verbatim fidelity."}
    with args.output.open("x") as handle:
        json.dump(report, handle, ensure_ascii=False, indent=2)
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
