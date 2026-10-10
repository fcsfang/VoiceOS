#!/usr/bin/env python3
"""Offline synthetic BGE evaluation; --download explicitly fetches pinned official files.

Research only: never opens a VoiceOS library, reads credentials, or creates relations.
Dependencies: torch==2.9.0 transformers==4.57.1 safetensors==0.6.2.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import time
import urllib.request

MODEL = "BAAI/bge-small-zh-v1.5"
REVISION = "7999e1d3359715c523056ef9478215996d62a620"
FILES = ("config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json",
         "special_tokens_map.json", "vocab.txt")
INSTRUCTION = "为这个句子生成表示以用于检索相关文章："
RERANKER = "BAAI/bge-reranker-base"
RERANK_REVISION = "2cfc18c9415c912f9d8155881c133215df768a70"
RERANK_FILES = ("config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json")


def artifacts(directory, model, revision, files, download):
    directory.mkdir(parents=True, exist_ok=True)
    for name in files:
        path = directory / name
        if not path.exists():
            if not download:
                raise ValueError("Pinned model files absent; opt into --download first")
            url = f"https://huggingface.co/{model}/resolve/{revision}/{name}"
            print(f"Downloading pinned official artifact: {model}/{name}", flush=True)
            temporary = path.with_suffix(path.suffix + ".partial")
            with urllib.request.urlopen(url, timeout=60) as response, temporary.open("wb") as out:
                while chunk := response.read(1024 * 1024):
                    out.write(chunk)
            temporary.replace(path)
    manifest = {name: hashlib.sha256((directory / name).read_bytes()).hexdigest() for name in files}
    manifest_path = directory / "voiceos-manifest.json"
    identity = dict(model=model, revision=revision, sha256=manifest,
                    bytes=sum((directory / name).stat().st_size for name in files))
    if manifest_path.exists():
        previous = json.loads(manifest_path.read_text())
        if any(previous[k] != identity[k] for k in ("model", "revision", "sha256")):
            raise ValueError("Model identity or file integrity changed")
    manifest_path.write_text(json.dumps(identity, indent=2) + "\n")
    return identity


def metrics(queries, rankings, threshold):
    tp = fp = expected = abstain = empty = top1 = top3 = positive = 0
    for q in queries:
        relevant = set(q["relevant"])
        ranked = rankings[q["id"]]
        selected = {x["id"] for x in ranked[:3] if x["score"] >= threshold}
        tp += len(selected & relevant)
        fp += len(selected - relevant)
        expected += len(relevant)
        if relevant:
            positive += 1
            top1 += ranked[0]["id"] in relevant
            top3 += bool({x["id"] for x in ranked[:3]} & relevant)
        else:
            empty += 1
            abstain += not selected
    return dict(precision=tp / (tp + fp) if tp + fp else 0,
                recall=tp / expected if expected else 0,
                relevant_found=tp, false_positive=fp, relevant_total=expected,
                no_match_abstained=abstain, no_match_total=empty,
                positive_top1=top1, positive_top3=top3, positive_queries=positive)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("fixture", type=Path)
    p.add_argument("model_dir", type=Path)
    p.add_argument("output", type=Path)
    p.add_argument("--download", action="store_true")
    p.add_argument("--reranker-dir", type=Path, help="Optional local top8 cross-encoder experiment")
    args = p.parse_args()
    fixture_bytes = args.fixture.read_bytes()
    fixture = json.loads(fixture_bytes)
    if fixture.get("synthetic") is not True:
        p.error("Only explicitly synthetic fixtures are supported")
    documents, queries = fixture["documents"], fixture["queries"]
    ids = [d["id"] for d in documents]
    if len(ids) != len(set(ids)) or len(queries) > 100 or len(documents) > 1000:
        p.error("Duplicate document identities or oversized fixture")
    if len({q["id"] for q in queries}) != len(queries):
        p.error("Duplicate query identities")
    if any(set(q["relevant"]) - set(ids) for q in queries):
        p.error("Unknown ground truth identity")
    if {q["split"] for q in queries} != {"calibration", "holdout"}:
        p.error("Require separate calibration and holdout queries")
    if any(not d["text"].strip() for d in documents) or any(not q["text"].strip() for q in queries):
        p.error("Empty text is not a valid fixture")
    identity = artifacts(args.model_dir, MODEL, REVISION, FILES, args.download)
    rerank_identity = artifacts(args.reranker_dir, RERANKER, RERANK_REVISION, RERANK_FILES, args.download) if args.reranker_dir else None
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TOKENIZERS_PARALLELISM"] = "false"
    import torch
    import transformers
    from transformers import AutoModel, AutoTokenizer
    torch.set_num_threads(4)
    start = time.perf_counter()
    tokenizer = AutoTokenizer.from_pretrained(args.model_dir, local_files_only=True, trust_remote_code=False)
    model = AutoModel.from_pretrained(args.model_dir, local_files_only=True,
                                     trust_remote_code=False, use_safetensors=True).eval()

    def encode(texts):
        vectors = []
        for offset in range(0, len(texts), 16):
            batch = texts[offset:offset + 16]
            if any(len(tokenizer.encode(t)) > 512 for t in batch):
                raise ValueError("Fixture would be truncated; split explicitly before evaluation")
            tokens = tokenizer(batch, padding=True, truncation=False, return_tensors="pt")
            with torch.inference_mode():
                cls = model(**tokens).last_hidden_state[:, 0]
                vectors.append(torch.nn.functional.normalize(cls, p=2, dim=1))
        return torch.cat(vectors)

    corpus = encode([d["text"] for d in documents])
    query_vectors = encode([INSTRUCTION + q["text"] for q in queries])
    scores = (query_vectors @ corpus.T).tolist()
    rankings = {q["id"]: sorted([dict(id=ids[j], score=s) for j, s in enumerate(row)],
                               key=lambda x: (-x["score"], x["id"]))
                for q, row in zip(queries, scores)}
    if args.reranker_dir:
        from transformers import AutoModelForSequenceClassification
        rerank_tokenizer = AutoTokenizer.from_pretrained(args.reranker_dir, local_files_only=True, trust_remote_code=False)
        reranker = AutoModelForSequenceClassification.from_pretrained(args.reranker_dir, local_files_only=True,
                                                                      trust_remote_code=False, use_safetensors=True).eval()
        by_id = {d["id"]: d["text"] for d in documents}
        candidates = [(q, hit) for q in queries for hit in rankings[q["id"]][:8]]
        reranked = {q["id"]: [] for q in queries}
        for offset in range(0, len(candidates), 8):
            batch = candidates[offset:offset + 8]
            pairs = [(q["text"], by_id[hit["id"]]) for q, hit in batch]
            if any(len(rerank_tokenizer.encode(a, b)) > 512 for a, b in pairs):
                raise ValueError("Rerank pair would be truncated")
            tokens = rerank_tokenizer(pairs, padding=True, truncation=False, return_tensors="pt")
            with torch.inference_mode():
                logits = reranker(**tokens).logits.view(-1)
                probabilities = logits.sigmoid().tolist()
            for (q, hit), logit, score in zip(batch, logits.tolist(), probabilities):
                reranked[q["id"]].append(dict(id=hit["id"], score=score, logit=logit, embedding_score=hit["score"]))
        rankings = {qid: sorted(rows, key=lambda x: (-x["score"], x["id"])) for qid, rows in reranked.items()}
    calibration = [q for q in queries if q["split"] == "calibration"]
    holdout = [q for q in queries if q["split"] == "holdout"]
    # Only calibration labels select threshold. Holdout never feeds selection.
    grid = [(i / 100, metrics(calibration, rankings, i / 100)) for i in range(0, 101)]
    admissible = [(t, m) for t, m in grid if m["precision"] >= .8 and
                  m["no_match_total"] > 0 and m["no_match_abstained"] == m["no_match_total"]]
    threshold = max(admissible, key=lambda x: (x[1]["recall"], x[1]["precision"], x[0]))[0] if admissible else 1.0
    result = dict(identity=identity, fixture_sha256=hashlib.sha256(fixture_bytes).hexdigest(),
                  synthetic=True, inference="CPU float32 CLS L2-normalized; instructed queries; offline",
                  dependencies=dict(torch=torch.__version__, transformers=transformers.__version__),
                  reranker=rerank_identity,
                  rerank_candidates=8 if rerank_identity else None,
                  score_meaning="Sigmoid of uncalibrated relevance logit; not truth or calibrated probability" if rerank_identity else "Cosine similarity; not truth",
                  seconds=time.perf_counter() - start, top_k=3, threshold=threshold,
                  threshold_selection="Calibration only: precision >=0.8 and all no-match abstain; maximize recall, precision, threshold",
                  calibration=metrics(calibration, rankings, threshold),
                  holdout=metrics(holdout, rankings, threshold), rankings=rankings)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({k: result[k] for k in ("seconds", "threshold", "calibration", "holdout")}, ensure_ascii=False))


if __name__ == "__main__":
    main()
