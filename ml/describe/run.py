"""Pipeline « Décrire la dépense » sur le Mac (MLX), suivi dans MLflow (expérience « Equipay-describe »).

  python run.py baseline                 → évalue Qwen3-4B sans entraînement (référence)
  python run.py train --epochs 2         → LoRA + évaluation complète + registre « equipay-describe »
  python run.py eval --adapter <dossier> → évalue un adaptateur existant
"""
import argparse
import datetime as dt
import json
import math
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

os.environ.setdefault("MLFLOW_DISABLE_AGENT_HINT", "1")

import mlflow  # noqa: E402
import yaml  # noqa: E402

import metrics as M  # noqa: E402
from schema import SYSTEM, user_message  # noqa: E402

HERE = Path(__file__).resolve().parent
DATA = HERE / "data"
MODELS = HERE / "models"
BASE = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
EXPERIMENT, REGISTRY = "Equipay-describe", "equipay-describe"


def manifest():
    return json.loads((DATA / "manifest.json").read_text())


def load_rows(name, limit=None):
    rows = [json.loads(l) for l in open(DATA / f"{name}_meta.jsonl")]
    return rows[:limit] if limit else rows


def evaluate(model_path, adapter, rows, batch=24):
    """Génère la réponse de chaque phrase (par lots) et calcule les métriques."""
    import mlx.core as mx
    from mlx_lm import batch_generate, load

    model, tok = load(model_path, adapter_path=str(adapter) if adapter else None)
    prompts = []
    for r in rows:
        meta = r["meta"]
        msgs = [{"role": "system", "content": SYSTEM},
                {"role": "user", "content": user_message(r["sentence"], meta["members"], meta["me"], dt.date.fromisoformat(meta["today"]), meta["currency"])}]
        prompts.append(tok.encode(tok.apply_chat_template(msgs, add_generation_prompt=True, tokenize=False), add_special_tokens=False))
    texts, latencies = [], []
    start_all = time.perf_counter()
    for i in range(0, len(prompts), batch):
        tic = time.perf_counter()
        out = batch_generate(model, tok, prompts[i:i + batch], max_tokens=320)
        mx.clear_cache()
        texts += out.texts
        latencies += [(time.perf_counter() - tic) / len(out.texts)] * len(out.texts)
        print(f"    {min(i + batch, len(prompts))}/{len(prompts)}", flush=True)
    total = time.perf_counter() - start_all
    scores, preds = [], []
    for r, text in zip(rows, texts):
        pred = M.parse_json(re.sub(r"<think>.*?</think>", "", text, flags=re.S))
        s = M.score(pred, r["target"], r["meta"])
        scores.append(s)
        preds.append({"sentence": r["sentence"], "style": r["meta"]["style"], "gold": r["target"], "raw": text, "pred": pred,
                      "ok": {f: s.get(f) for f in M.FIELDS if f in s}, "ok_all": s["ok_all"]})
    metrics = M.aggregate(scores, latencies)
    metrics["throughput_examples_per_s"] = len(rows) / total
    metrics["peak_memory_gb"] = (getattr(mx, "get_peak_memory", None) or mx.metal.get_peak_memory)() / 1e9
    del model
    return metrics, scores, preds


def log_eval(prefix, folder, metrics, scores, preds, title):
    mlflow.log_metrics({f"{prefix}{k}": float(v) for k, v in metrics.items()})
    for key, name in [("style", "style"), ("kind", "participants"), ("split_type", "repartition")]:
        for g, vals in M.breakdown(scores, key).items():
            safe = re.sub(r"[^A-Za-z0-9_]", "_", str(g))
            mlflow.log_metrics({f"{prefix}{name}_{safe}_{k}": float(v) for k, v in vals.items()})
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        (tmp / "metrics.json").write_text(json.dumps(metrics, indent=2, ensure_ascii=False))
        for key in ("style", "kind", "split_type"):
            (tmp / f"par_{key}.json").write_text(json.dumps(M.breakdown(scores, key), indent=2, ensure_ascii=False))
        (tmp / "confusion.json").write_text(json.dumps(M.confusions(scores), indent=2, ensure_ascii=False))
        with open(tmp / "predictions.jsonl", "w") as f:
            for p in preds:
                f.write(json.dumps(p, ensure_ascii=False) + "\n")
        for name, fig in M.figures(scores, title).items():
            fig.savefig(tmp / name, dpi=130)
        mlflow.log_artifacts(str(tmp), folder)


def full_eval(model_path, adapter, label, limit=None):
    results = {}
    for split, prefix in [("test", "eval_"), ("manual", "manual_eval_")]:
        rows = load_rows(split, limit)
        print(f"Évaluation {label} — {split} ({len(rows)} phrases)…", flush=True)
        m, scores, preds = evaluate(model_path, adapter, rows)
        log_eval(prefix, prefix.rstrip("_"), m, scores, preds, f"{label} ({split})")
        results[split] = m
        print(f"  {split}: score {m['score']:.3f} | exact {m['exact_match']:.1%} | montant {m['amount_accuracy']:.1%} | "
              f"participants {m['participants_accuracy']:.1%} | payeur {m['paid_by_accuracy']:.1%} | date {m['date_accuracy']:.1%}", flush=True)
    return results


def setup():
    mlflow.set_tracking_uri(os.environ.get("MLFLOW_TRACKING_URI", "http://127.0.0.1:5000"))
    mlflow.set_experiment(EXPERIMENT)


def common_params():
    man = manifest()
    return {"base_model": BASE, "dataset_sha": man["dataset_sha"], "train_examples": man["sizes"]["train"],
            "valid_examples": man["sizes"]["valid"], "test_examples": man["sizes"]["test"], "manual_examples": man["sizes"]["manual"],
            "score_weights": json.dumps(M.SCORE_WEIGHTS)}


def cmd_baseline(args):
    setup()
    with mlflow.start_run(run_name="baseline-qwen3-4b-zero-shot"):
        mlflow.set_tags({"stage": "baseline", "dataset_sha": manifest()["dataset_sha"]})
        mlflow.log_params(common_params())
        mlflow.log_artifact(str(DATA / "manifest.json"), "dataset")
        full_eval(BASE, None, "base", args.limit)


def cmd_train(args):
    setup()
    man = manifest()
    iters = args.iters or math.ceil(man["sizes"]["train"] / args.batch_size * args.epochs)
    name = f"lora-qwen3-4b-r{args.rank}-L{args.layers}-{args.epochs:g}ep"
    adapter = MODELS / f"{name}-{time.strftime('%Y%m%d-%H%M%S')}"
    with mlflow.start_run(run_name=name) as run:
        mlflow.set_tags({"stage": "fine-tuned", "dataset_sha": man["dataset_sha"], "status": "training"})
        mlflow.log_params({**common_params(), "iters": iters, "epochs": args.epochs, "learning_rate": args.lr, "batch_size": args.batch_size,
                           "num_layers": args.layers, "lora_rank": args.rank, "lora_scale": args.scale, "lora_dropout": 0.05,
                           "mask_prompt": True, "max_seq_length": 768, "seed": 42, "lr_schedule": "cosine, warmup 3%"})
        mlflow.log_artifact(str(DATA / "manifest.json"), "dataset")
        for f in ("generate.py", "build.py", "schema.py", "metrics.py", "run.py"):
            mlflow.log_artifact(str(HERE / f), "code")
        config = {"lora_parameters": {"rank": args.rank, "scale": args.scale, "dropout": 0.05},
                  "lr_schedule": {"name": "cosine_decay", "warmup": max(1, iters // 33), "arguments": [args.lr, iters, args.lr / 20]}}
        with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as f:
            yaml.safe_dump(config, f)
        cmd = [sys.executable, "-m", "mlx_lm", "lora", "--config", f.name, "--model", BASE, "--train", "--data", str(DATA),
               "--iters", str(iters), "--batch-size", str(args.batch_size), "--num-layers", str(args.layers),
               "--learning-rate", str(args.lr), "--mask-prompt", "--steps-per-report", "20", "--steps-per-eval", str(args.eval_every),
               "--val-batches", "40", "--save-every", str(args.eval_every), "--max-seq-length", "768", "--seed", "42",
               "--adapter-path", str(adapter)] + (["--grad-checkpoint"] if args.grad_checkpoint else [])
        print("Entraînement LoRA :", " ".join(cmd[3:]), flush=True)
        start = time.perf_counter()
        best = (float("inf"), 0)
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for line in proc.stdout:
            print(line, end="", flush=True)
            plain = re.sub(r"\x1b\[[0-9;]*m", "", line)
            # Tableau de mlx-lm : « 500   val 0.133   2.19s » et « 500   0.166 ▼   85   10.4k »
            if m := re.match(r"\s*(\d+)\s+val\s+(\d+\.\d+)", plain):
                step, loss = int(m[1]), float(m[2])
                mlflow.log_metric("val_loss", loss, step=step)
                mlflow.log_metric("val_perplexity", math.exp(min(loss, 20)), step=step)
                if loss < best[0]:
                    best = (loss, step)
            elif m := re.match(r"\s*(\d+)\s+(\d+\.\d+)\s+\S*\s+(\d+)\s+([\d.]+)(k?)", plain):
                step = int(m[1])
                mlflow.log_metrics({"train_loss": float(m[2]), "trained_tokens_per_s": float(m[3]),
                                    "trained_tokens": float(m[4]) * (1000 if m[5] else 1),
                                    "epoch": step * args.batch_size / man["sizes"]["train"],
                                    "elapsed_min": (time.perf_counter() - start) / 60}, step=step)
        if proc.wait() != 0:
            mlflow.set_tag("status", "failed")
            raise SystemExit("L'entraînement a échoué")
        # Meilleur point de validation : on garde ce checkpoint comme adaptateur final
        best_file = adapter / f"{best[1]:07d}_adapters.safetensors"
        if best[1] and best_file.exists():
            (adapter / "final_adapters.safetensors").write_bytes((adapter / "adapters.safetensors").read_bytes())
            (adapter / "adapters.safetensors").write_bytes(best_file.read_bytes())
        mlflow.log_metrics({"best_val_loss": best[0], "best_step": best[1], "train_time_s": time.perf_counter() - start})
        mlflow.set_tag("status", "evaluating")
        for f in ("adapters.safetensors", "adapter_config.json"):
            mlflow.log_artifact(str(adapter / f), "adapter")
        res = full_eval(BASE, adapter, "affiné", args.limit)
        # Comparaison avec la référence (même jeu de données)
        client = mlflow.MlflowClient()
        base_runs = client.search_runs([run.info.experiment_id], f"tags.stage = 'baseline' and tags.dataset_sha = '{man['dataset_sha']}'",
                                       order_by=["start_time DESC"], max_results=1)
        if base_runs:
            b = base_runs[0].data.metrics
            mlflow.log_metrics({"eval_score_gain_vs_base": res["test"]["score"] - b.get("eval_score", 0),
                                "manual_eval_score_gain_vs_base": res["manual"]["score"] - b.get("manual_eval_score", 0)})
        version = register(client, run, res, man)
        mlflow.set_tags({"status": "done", "registered_version": version})
        print(f"\n✓ Run {run.info.run_id} — test {res['test']['score']:.3f}, manuel {res['manual']['score']:.3f}, adaptateur {adapter}")


def register(client, run, res, man):
    try:
        client.create_registered_model(REGISTRY, description="Décrire la dépense : phrase → dépense (LoRA Qwen3-4B, MLX)")
    except Exception:
        pass
    v = client.create_model_version(REGISTRY, source=f"{run.info.artifact_uri}/adapter", run_id=run.info.run_id)
    for k, val in {"dataset_sha": man["dataset_sha"], "eval_score": f"{res['test']['score']:.4f}",
                   "manual_eval_score": f"{res['manual']['score']:.4f}", "base_model": BASE, "format": "mlx-lora"}.items():
        client.set_model_version_tag(REGISTRY, v.version, k, val)
    try:
        champ = client.get_model_version_by_alias(REGISTRY, "champion")
        better = res["test"]["score"] > float(champ.tags.get("eval_score", 0))
    except Exception:
        better = True
    if better:
        client.set_registered_model_alias(REGISTRY, "champion", v.version)
    print(f"Registre : {REGISTRY} v{v.version}" + (" (champion)" if better else ""))
    return v.version


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("baseline")
    b.add_argument("--limit", type=int)
    t = sub.add_parser("train")
    t.add_argument("--epochs", type=float, default=1)
    t.add_argument("--iters", type=int)
    t.add_argument("--lr", type=float, default=1e-4)
    t.add_argument("--batch-size", type=int, default=4)
    t.add_argument("--layers", type=int, default=16)
    t.add_argument("--rank", type=int, default=16)
    t.add_argument("--scale", type=float, default=20.0)
    t.add_argument("--eval-every", type=int, default=500)
    t.add_argument("--grad-checkpoint", action="store_true")
    t.add_argument("--limit", type=int)
    e = sub.add_parser("eval")
    e.add_argument("--adapter", required=True)
    e.add_argument("--limit", type=int)
    args = p.parse_args()
    if args.cmd == "baseline":
        cmd_baseline(args)
    elif args.cmd == "train":
        cmd_train(args)
    else:
        setup()
        with mlflow.start_run(run_name=f"eval-{Path(args.adapter).name}"):
            full_eval(BASE, args.adapter, "adaptateur", args.limit)


if __name__ == "__main__":
    main()
