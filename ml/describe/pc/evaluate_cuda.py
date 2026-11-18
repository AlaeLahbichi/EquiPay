"""Évaluation du modèle « Décrire la dépense » sur GPU (PyTorch), mêmes métriques que le Mac (metrics.py).

Utilisé à la fin de train_cuda.py (même run MLflow), ou seul pour réévaluer un run existant :
  python evaluate_cuda.py --run-id <RUN_ID>            → adaptateur du run + modèle de base
  python evaluate_cuda.py --run-id <RUN_ID> --limit 40 → essai rapide

Préfixes MLflow : eval_ (affiné, 800 phrases de test), manual_eval_ (affiné, 50 phrases écrites à la main),
base_eval_ et base_manual_eval_ (modèle de base sans adaptateur), plus les gains eval_score_gain*.
"""
import argparse
import datetime as dt
import json
import os
import re
import tempfile
import time
from pathlib import Path

import torch

import metrics as M
from schema import SYSTEM, user_message

HERE = Path(__file__).resolve().parent
DATA = HERE / "data"
MAX_NEW_TOKENS = 320


def load_rows(name: str, limit: int | None = None) -> list[dict]:
    with open(DATA / f"{name}_meta.jsonl", encoding="utf-8") as f:
        rows = [json.loads(line) for line in f]
    if limit:  # échantillon réparti sur tout le jeu
        rows = rows[:: max(1, len(rows) // limit)][:limit]
    return rows


def prompt_text(tokenizer, row: dict) -> str:
    meta = row["meta"]
    msgs = [{"role": "system", "content": SYSTEM},
            {"role": "user", "content": user_message(row["sentence"], meta["members"], meta["me"],
                                                     dt.date.fromisoformat(meta["today"]), meta["currency"])}]
    return tokenizer.apply_chat_template(msgs, add_generation_prompt=True, tokenize=False)


@torch.no_grad()
def generate(model, tokenizer, rows: list[dict], batch_size: int = 32) -> tuple[list[str], list[float]]:
    model.eval()
    side, tokenizer.padding_side = tokenizer.padding_side, "left"
    texts, latencies = [], []
    try:
        for i in range(0, len(rows), batch_size):
            batch = rows[i:i + batch_size]
            enc = tokenizer([prompt_text(tokenizer, r) for r in batch], return_tensors="pt", padding=True,
                            add_special_tokens=False).to(model.device)
            torch.cuda.synchronize() if torch.cuda.is_available() else None
            start = time.perf_counter()
            out = model.generate(**enc, max_new_tokens=MAX_NEW_TOKENS, do_sample=False, temperature=None, top_p=None,
                                 top_k=None, pad_token_id=tokenizer.pad_token_id)
            torch.cuda.synchronize() if torch.cuda.is_available() else None
            per = (time.perf_counter() - start) / len(batch)
            for row in out[:, enc["input_ids"].shape[1]:]:
                texts.append(re.sub(r"<think>.*?</think>", "", tokenizer.decode(row, skip_special_tokens=True), flags=re.S).strip())
                latencies.append(per)
            print(f"  génération {min(i + batch_size, len(rows))}/{len(rows)}", flush=True)
    finally:
        tokenizer.padding_side = side
    return texts, latencies


def evaluate(model, tokenizer, rows: list[dict], batch_size: int = 32):
    """Renvoie (métriques, scores par phrase, prédictions)."""
    texts, latencies = generate(model, tokenizer, rows, batch_size)
    scores, preds = [], []
    for r, text in zip(rows, texts):
        pred = M.parse_json(text)
        s = M.score(pred, r["target"], r["meta"])
        scores.append(s)
        preds.append({"sentence": r["sentence"], "style": r["meta"]["style"], "members": r["meta"]["members"],
                      "today": r["meta"]["today"], "gold": r["target"], "raw": text, "pred": pred,
                      "ok": {f: s.get(f) for f in M.FIELDS if f in s}, "ok_all": s["ok_all"]})
    metrics = M.aggregate(scores, latencies)
    if torch.cuda.is_available():
        metrics["peak_gpu_mem_gb"] = torch.cuda.max_memory_allocated() / 1e9
    return metrics, scores, preds


def log_evaluation(prefix: str, metrics: dict, scores: list, preds: list, title: str) -> None:
    import mlflow

    mlflow.log_metrics({f"{prefix}{k}": float(v) for k, v in metrics.items()})
    for key, name in [("style", "style"), ("kind", "participants"), ("split_type", "repartition")]:
        for g, vals in M.breakdown(scores, key).items():
            safe = re.sub(r"[^A-Za-z0-9_]", "_", str(g))
            mlflow.log_metrics({f"{prefix}{name}_{safe}_{k}": float(v) for k, v in vals.items()})
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        (tmp / "metrics.json").write_text(json.dumps(metrics, indent=2, ensure_ascii=False), encoding="utf-8")
        for key in ("style", "kind", "split_type"):
            (tmp / f"par_{key}.json").write_text(json.dumps(M.breakdown(scores, key), indent=2, ensure_ascii=False), encoding="utf-8")
        (tmp / "confusion.json").write_text(json.dumps(M.confusions(scores), indent=2, ensure_ascii=False), encoding="utf-8")
        with open(tmp / "predictions.jsonl", "w", encoding="utf-8") as f:
            for p in preds:
                f.write(json.dumps(p, ensure_ascii=False) + "\n")
        for name, fig in M.figures(scores, title).items():
            fig.savefig(tmp / name, dpi=130)
        mlflow.log_artifacts(str(tmp), prefix.rstrip("_"))


def comparison_figure(results: dict):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    keys = ["score", "exact_match", "amount_accuracy", "participants_accuracy", "paid_by_accuracy", "date_accuracy",
            "split_accuracy", "currency_accuracy", "is_expense_accuracy"]
    fig, ax = plt.subplots(figsize=(11, 4.5))
    width = 0.8 / len(results)
    for i, (name, m) in enumerate(results.items()):
        ax.bar([k + i * width - 0.4 + width / 2 for k in range(len(keys))], [m[k] for k in keys], width, label=name)
    ax.set_xticks(range(len(keys)), keys, rotation=25, ha="right")
    ax.set_ylim(0, 1)
    ax.legend()
    ax.set_title("Modèle de base vs affiné")
    fig.tight_layout()
    return fig


def full_evaluation(model, tokenizer, title: str, batch_size: int = 32, limit: int | None = None,
                    with_baseline: bool = True) -> dict:
    """Évalue le modèle affiné puis le modèle de base (adaptateur désactivé), dans le run MLflow actif."""
    import mlflow

    results = {}
    for split, prefix in [("test", "eval_"), ("manual", "manual_eval_")]:
        rows = load_rows(split, limit)
        print(f"Évaluation du modèle affiné — {split} ({len(rows)} phrases)…", flush=True)
        m, scores, preds = evaluate(model, tokenizer, rows, batch_size)
        log_evaluation(prefix, m, scores, preds, f"{title} — affiné ({split})")
        results[f"affiné {split}"] = m
        print(f"  {split} : score {m['score']:.3f}, dépense entièrement juste {m['exact_match']:.1%}", flush=True)
    if with_baseline:
        with model.disable_adapter():
            for split, prefix in [("test", "base_eval_"), ("manual", "base_manual_eval_")]:
                rows = load_rows(split, limit)
                print(f"Évaluation du modèle de base — {split} ({len(rows)} phrases)…", flush=True)
                m, scores, preds = evaluate(model, tokenizer, rows, batch_size)
                log_evaluation(prefix, m, scores, preds, f"{title} — base ({split})")
                results[f"base {split}"] = m
        mlflow.log_metrics({"eval_score_gain": results["affiné test"]["score"] - results["base test"]["score"],
                            "manual_eval_score_gain": results["affiné manual"]["score"] - results["base manual"]["score"]})
        with tempfile.TemporaryDirectory() as tmp:
            comparison_figure({k: v for k, v in results.items() if k.endswith("test")}).savefig(Path(tmp) / "base_vs_affine.png", dpi=130)
            mlflow.log_artifacts(tmp, "eval")
    return results["affiné test"]


def main() -> None:
    import mlflow
    from peft import PeftModel
    from transformers import AutoModelForCausalLM, AutoTokenizer

    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--tracking-uri", default=os.environ.get("EQUIPAY_MLFLOW_URI", "http://192.168.1.58:5000"))
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--limit", type=int)
    parser.add_argument("--no-baseline", action="store_true")
    args = parser.parse_args()
    mlflow.set_tracking_uri(args.tracking_uri)
    run = mlflow.get_run(args.run_id)
    base_model = run.data.tags["base_model"]
    with tempfile.TemporaryDirectory() as tmp:
        adapter = mlflow.artifacts.download_artifacts(run_id=args.run_id, artifact_path="adapter", dst_path=tmp)
        tokenizer = AutoTokenizer.from_pretrained(base_model)
        if tokenizer.pad_token is None:
            tokenizer.pad_token = tokenizer.eos_token
        device = "cuda" if torch.cuda.is_available() else ("mps" if torch.backends.mps.is_available() else "cpu")
        model = AutoModelForCausalLM.from_pretrained(base_model, dtype=torch.bfloat16).to(device)
        model = PeftModel.from_pretrained(model, adapter)
        with mlflow.start_run(run_id=args.run_id):
            full_evaluation(model, tokenizer, run.info.run_name, args.batch_size, args.limit, not args.no_baseline)
            mlflow.set_tag("status", "awaiting_mac_import")


if __name__ == "__main__":
    main()
